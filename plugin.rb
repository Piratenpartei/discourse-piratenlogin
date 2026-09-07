# frozen_string_literal: true

# name: discourse-ekklesia
# about: Add support for Piratenlogin as a login provider
# version: 2020.09.dev0
# authors: David Taylor/Tobias Stenzel
# url: https://github.com/Piratenpartei/discourse-ekklesia

require_relative "lib/omniauth_open_id_connect"
require_relative "lib/piratenlogin_group_sync"
require_relative "lib/piratenlogin_authenticator"

auth_provider authenticator: PiratenloginAuthenticator.new()

register_css <<CSS

.btn-social.piratenlogin {
  background: rgb(253, 195, 0);
  color: black;
}
CSS

