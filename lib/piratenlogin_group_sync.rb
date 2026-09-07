# frozen_string_literal: true

# Mirrors a member's Keycloak group onto Discourse groups.
#
# In the Piratenlogin realm every member sits in exactly one group below
# /Worldwide, named after their federal state -- HE, BY, HB, HH and so on, each
# carrying a display_name attribute like "Bayern". MemberDataImport rewrites
# that membership from the AF_BEO export every night and removes the siblings,
# so it is the single source of truth for which state a member belongs to.
#
# The client's `user_roles` scope already puts those Gliederungsnamen into the
# same `roles` claim the required-role check reads -- "Piratenpartei
# Deutschland" is the parent group's. The Discourse groups are called
# "LV Bayern", so the mapping is one row per Landesverband. Claim name, mapping
# and parent path are all settings, so a realm that emits bare group names, or
# full paths from a group membership mapper, works too.
#
# Two properties this deliberately keeps:
#
#   * Only Discourse groups named in piratenlogin_group_mapping are ever
#     touched, and never an automatic one. Without that allowlist a group
#     created in Keycloak could hand out membership of a staff group or a
#     trust level.
#   * A token carrying no group claim at all changes nothing. A mapper that is
#     missing or misnamed then reads as "no information" rather than "member of
#     nothing", which would otherwise strip the state group from every user on
#     their next login.
class PiratenloginGroupSync
  # Rows of piratenlogin_group_mapping are "<keycloak group>|<discourse group>".
  # A row without a separator maps a name onto itself.
  ROW_SEPARATOR = "|"

  # The claim's values, or nil when the token does not carry the claim at all.
  # Callers have to keep those two apart -- see the note above.
  def self.claim_values(raw_info)
    return nil if raw_info.nil?

    claim = SiteSetting.piratenlogin_groups_claim.to_s.strip
    return nil if claim.empty?

    value = raw_info[claim.to_sym]
    value = raw_info[claim] if value.nil?
    return nil if value.nil?

    (value.is_a?(Array) ? value : [value]).map(&:to_s)
  end

  def self.sync!(user, claim_values)
    return if user.nil? || claim_values.nil?
    return unless SiteSetting.piratenlogin_group_sync_enabled

    map = mapping
    wanted =
      claim_values
        .flat_map { |value| candidate_names(value) }
        .filter_map { |name| map[name.downcase] }
        .map(&:downcase)
        .uniq

    apply(user, wanted)
  end

  # Drop every managed group. Used when a member loses the role that lets them
  # use Discourse at all, and when a login is moved to a different account.
  def self.revoke!(user)
    return if user.nil?
    return unless SiteSetting.piratenlogin_group_sync_enabled

    apply(user, [])
  end

  # Normalised keycloak group name => Discourse group name, as configured.
  def self.mapping
    SiteSetting
      .piratenlogin_group_mapping
      .to_s
      .split("\n")
      .each_with_object({}) do |row, acc|
        source, target = row.split(ROW_SEPARATOR, 2).map { |value| value.to_s.strip }
        next if source.blank? || source.start_with?("#")
        acc[source.downcase] = target.presence || source
      end
  end

  # The Discourse groups this class is allowed to add to and remove from.
  #
  # A mapping target is matched against both `name` and `full_name`: a Discourse
  # group name cannot contain a space, so "LV Bayern" only ever exists as the
  # full name of a group called something like "LV_Bayern".
  #
  # Automatic groups are Discourse's own -- trust levels, staff -- and are
  # excluded even when a mapping row names one.
  def self.managed_groups
    names = mapping.values.map(&:downcase).uniq
    return Group.none if names.empty?

    Group
      .where(automatic: false)
      .where("lower(name) IN (:names) OR lower(full_name) IN (:names)", names: names)
  end

  # The group names a single claim value can stand for.
  #
  # Keycloak's group membership mapper emits either a bare name ("HE") or a
  # full path ("/Worldwide/HE"), depending on whether "Full group path" is on,
  # so both forms have to resolve to the same mapping row. A path is only
  # accepted below piratenlogin_group_parent_path -- an "HE" somewhere else in
  # the tree is a different group and must not grant the state group here.
  #
  # Every segment below the parent is a candidate, not just the last one: the
  # realm allows Kreisverband groups under a state, and /Worldwide/HE/KV Kassel
  # still means the member is in HE.
  def self.candidate_names(value)
    raw = value.to_s.strip
    return [] if raw.empty?
    return [raw] unless raw.include?("/")

    segments = raw.split("/").reject(&:empty?)
    parent = SiteSetting.piratenlogin_group_parent_path.to_s.split("/").reject(&:empty?)
    return segments if parent.empty?
    return [] unless segments.length > parent.length
    return [] unless segments.first(parent.length).map(&:downcase) == parent.map(&:downcase)

    segments.drop(parent.length)
  end

  def self.apply(user, wanted)
    managed_groups.find_each do |group|
      identifiers = [group.name, group.full_name].compact_blank.map(&:downcase)
      member = GroupUser.exists?(group_id: group.id, user_id: user.id)

      if identifiers.intersect?(wanted)
        group.add(user) unless member
      elsif member
        group.remove(user)
      end
    end
  end
  private_class_method :apply
end
