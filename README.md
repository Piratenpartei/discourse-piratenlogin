# discourse-piratenlogin

Piratenlogin (Keycloak, OpenID Connect) as a Discourse login provider.

Beyond authenticating, the plugin keeps two kinds of group membership in step
with Keycloak:

- the `Piraten` group, which every member with the `Piratenpartei Deutschland`
  role gets and loses again when that role goes away, and
- the **Landesverband**, mirrored from the member's Keycloak group onto the
  Discourse group of the same name.

## Landesverband sync

In the Piratenlogin realm every member sits in exactly one group below
`/Worldwide`, named after their federal state — `HE`, `BY`, `HB`, `HH` and so
on — each carrying a `display_name` attribute like `Bayern`.
[MemberDataImport](https://github.com/Piratenpartei/MemberDataImport) rewrites
that membership from the nightly AF_BEO export and removes the siblings, so
Keycloak is the single source of truth for which state a member belongs to.

The `diskussion_piratenpartei_de` client already has the `user_roles` scope
("Rollen des Users inkl. Gliederungsnamen"), which puts those names into the
same `roles` claim the required-role check reads — `Piratenpartei Deutschland`
is the parent group's. So **no Keycloak change is needed**: the claim carries
`Bayern`, the forum group is called `LV Bayern`, and the default mapping is one
row per Landesverband bridging the two.

On every login the plugin reads the claim, resolves each value through
`piratenlogin_group_mapping`, and adds the user to the group that matches while
removing them from the other mapped ones. Account creation applies the same
state, so a new member lands in their Landesverband on first login.

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `piratenlogin_group_sync_enabled` | `false` | Master switch. Off means no group is ever added or removed. |
| `piratenlogin_groups_claim` | `roles` | Claim carrying the Gliederungsnamen. |
| `piratenlogin_group_parent_path` | *(empty)* | Only for a realm that emits full group paths — see below. |
| `piratenlogin_group_mapping` | the 16 state names | One `keycloak group\|discourse group` per line; without `\|` the name is used as is. |

The forum's Landesverband groups are named after the state itself — `Bayern`,
`Brandenburg`, `Hessen` — and the claim carries the Keycloak group's
`display_name`, which is the same string. The default is therefore one bare
name per line, mapping each onto itself.

Mapping targets are matched against **both** a group's `name` and its
`full_name`, so a forum that spells them out (`full_name: "Hessische Piraten"`,
`name: "Hessen"`) still resolves. Where neither matches, give the target
explicitly: `Hessen|LV_Hessen`.

A state whose group does not exist in the forum is skipped silently — the
mapping may list all sixteen even where only a few groups have been created.

The left-hand side is whatever the claim actually carries. If a realm emits the
group name instead of its display name, the rows become `HE|Hessen`.

If the realm is ever switched to a group membership mapper with *Full group
path* on, values arrive as `/Worldwide/BY` instead. Set
`piratenlogin_groups_claim` to that claim and `piratenlogin_group_parent_path`
to `/Worldwide`. Every segment below the parent counts, so
`/Worldwide/BY/KV München` still resolves to `BY`.

### Two deliberate properties

**The mapping is the allowlist.** Only the Discourse groups named on the
right-hand side are ever touched, and automatic groups — trust levels, staff —
are excluded even if one is named. Without that, whoever can create a group in
Keycloak could hand out `staff` in Discourse.

**A missing claim changes nothing.** A token that does not carry the claim at
all reads as *no information*, not as *member of no group*. A mapper that is
misconfigured or removed therefore leaves memberships alone instead of
stripping every Landesverband from every user on their next login. An empty
claim (`[]`) does mean "in no group" and does remove them.

### Rolling it out

1. Turn on `piratenlogin_verbose_logging`, log in once, and check `/logs` for
   what the `roles` claim actually contains.
2. Line the left-hand side of `piratenlogin_group_mapping` up with those
   values — the default assumes they are the groups' `display_name`.
3. Turn on `piratenlogin_group_sync_enabled`, then turn the verbose logging
   back off.

The sync runs per login, so the forum converges as members come back rather
than in one pass.
