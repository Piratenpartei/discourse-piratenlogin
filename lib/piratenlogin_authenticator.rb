# frozen_string_literal: true
class PiratenloginAuthenticator < Auth::ManagedAuthenticator
  def name
    'piratenlogin'
  end

  def can_revoke?
    true
  end

  def can_connect_existing_user?
    true
  end

  def enabled?
    SiteSetting.piratenlogin_enabled
  end

  def always_update_user_email?
    false
  end

  def register_middleware(omniauth)

    omniauth.provider :openid_connect,
      name: :piratenlogin,
      cache: lambda { |key, &blk| Rails.cache.fetch(key, expires_in: 10.minutes, &blk) },
      error_handler: lambda { |error, message|
        handlers = SiteSetting.piratenlogin_error_redirects.split("\n")
        handlers.each do |row|
          parts = row.split("|")
          return parts[1] if message.include? parts[0]
        end
        nil
      },
      verbose_logger: lambda { |message|
        return unless SiteSetting.piratenlogin_verbose_logging
        Rails.logger.warn("Piratenlogin: #{message}")
      },
      setup: lambda { |env|
        opts = env['omniauth.strategy'].options

        token_params = {}
        token_params[:scope] = SiteSetting.piratenlogin_token_scope if SiteSetting.piratenlogin_token_scope.present?

        opts.deep_merge!(
          client_id: SiteSetting.piratenlogin_client_id,
          client_secret: SiteSetting.piratenlogin_client_secret,
          client_options: {
            discovery_document: SiteSetting.piratenlogin_discovery_document,
          },
          scope: SiteSetting.piratenlogin_authorize_scope,
          token_params: token_params,
          passthrough_authorize_options: SiteSetting.piratenlogin_authorize_parameters.split("|")
        )
      }
  end

  def after_authenticate(auth_token, existing_account: nil)
    # Try and find an association for this account.
    association = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])

    extra = auth_token[:extra] || {}

    has_required_role = extra[:raw_info].fetch(:roles, []).include?("Piratenpartei Deutschland")

    result = Auth::Result.new

    # Check required role for new users.
    if association.user.nil? && !has_required_role
      result.failed = true
      result.failed_reason = I18n.t("piratenlogin.alert_piratenlogin_not_allowed")
      return result
    end

    # Reconnecting to existing account
    if can_connect_existing_user? && existing_account
      if association.user.nil?
        association.user = existing_account
      elsif existing_account.id != association.user_id
        # Previous user associated with the login loses auto group.
        # We don't want users to create multiple users with special permissions.
        remove_auto_group(association.user)
        association.user = existing_account
      # else: nothing changed
      end
    end

    association.info = auth_token[:info] || {}
    association.credentials = auth_token[:credentials] || {}

    association.last_used = Time.zone.now

    # Save to the DB. Do this even if we don't have a user - it might be linked up later in after_create_account.
    association.save!

    retrieve_avatar(association.user, association.info["image"])
    retrieve_profile(association.user, association.info)

    # nil when the token carries no group claim, which means "unknown" and not
    # "member of nothing" -- see PiratenloginGroupSync.
    groups = PiratenloginGroupSync.claim_values(extra[:raw_info])

    if association.user
      if has_required_role
        add_auto_group(association.user)
        PiratenloginGroupSync.sync!(association.user, groups)
      else
        remove_auto_group(association.user)
      end
    end

    info = auth_token[:info]
    result.username = info[:nickname]
    result.extra_data = {
      provider: auth_token[:provider],
      uid: auth_token[:uid],
      groups: groups
    }
    result.user = association.user

    # only for development: supply valid mail adress to skip mail confirmation
    #result.email = 'fake@adress.is'
    #result.email_valid = true
    result
  end

  def after_create_account(user, auth)
    auth_token = auth[:extra_data]
    association = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])
    association.user = user

    add_auto_group(user)
    # Round-tripped through the session, so the key may have lost its symbol.
    PiratenloginGroupSync.sync!(user, auth_token[:groups] || auth_token["groups"])

    association.save!

    retrieve_avatar(user, association.info["image"])
    retrieve_profile(user, association.info)
  end

  def add_auto_group(user)
    unless user.groups.find_by(name: 'Piraten').present?
      auto_group = Group.where(name: 'Piraten').first
      return unless auto_group.present?
      user.groups << auto_group
      user.save!
    end
  end

  def remove_auto_group(user)
      auto_group = Group.where(name: 'Piraten').first
      user.groups.delete(auto_group)
      # Discourse doesn't remove the title itself
      user.title = nil
      user.save!
      # A member who may not use the forum keeps no state group either.
      PiratenloginGroupSync.revoke!(user)
  end
end
