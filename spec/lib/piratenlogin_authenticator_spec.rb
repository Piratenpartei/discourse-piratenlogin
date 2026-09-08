# frozen_string_literal: true

require 'rails_helper'
require_relative '../../lib/piratenlogin_authenticator'

describe PiratenloginAuthenticator do
  let(:authenticator) { described_class.new }
  let(:user) { Fabricate(:user) }
  let(:group) { Fabricate(:group, name: 'Piraten', title: 'Pirat') }
  let(:auth_token) { OmniAuth::AuthHash.new(
    provider: "piratenlogin",
    uid: "123456789",
    info: {
        nickname: "pirat"
    },
    extra: {
      raw_info: {
        roles: []
      }
    }
  )}

  before(:example) do
    group.save!
  end

  context "when user has required role" do
    before do
      auth_token[:extra][:raw_info][:roles] = ["Piratenpartei Deutschland", "some"]
    end

    it "allows initial login" do
      result = authenticator.after_authenticate(auth_token)
      expect(result.username).to eq("pirat")
      expect(result.failed).to eq(false)
    end

    it "allows subsequent login and sets auto group" do
      assoc = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])
      assoc.user = user
      assoc.save!
      result = authenticator.after_authenticate(auth_token)
      expect(result.failed).to eq(false)
      expect(result.user).to eq(user)
      expect(result.user.groups).to include(group)
    end

  end

  context "when user doesn't have required role" do
    it "refuses initial login" do
      auth_token[:extra][:raw_info][:roles] = ["Guest", "invalid"]
      result = authenticator.after_authenticate(auth_token)
      expect(result.failed).to eq(true)
    end

    it "allows login but removes auto group for existing user" do
      assoc = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])
      assoc.user = user
      user.groups << group
      user.title = 'Pirat'
      user.save!
      assoc.save!
      result = authenticator.after_authenticate(auth_token)
      expect(result.failed).to eq(false)
      expect(result.user).to eq(user)
      expect(result.user.groups).not_to include(group)
      expect(result.user.title).to eq(nil)
    end
  end

  context "after account has been created" do
    it "sets auto group" do
      auth = { extra_data: auth_token }
      authenticator.after_create_account(user, auth)
      expect(user.groups).to include(group)
    end
  end

  context "with group sync enabled" do
    let!(:state_group) { Fabricate(:group, name: 'Hessen', full_name: 'Hessische Piraten') }

    before do
      SiteSetting.piratenlogin_group_sync_enabled = true
      SiteSetting.piratenlogin_groups_claim = 'roles'
      SiteSetting.piratenlogin_group_parent_path = ''
      SiteSetting.piratenlogin_group_mapping = 'Hessen'
      # The user_roles scope puts the Gliederungsnamen into the same claim the
      # required-role check reads.
      auth_token[:extra][:raw_info][:roles] = ["Piratenpartei Deutschland", "Hessen"]
    end

    it "assigns the Landesverband group on login" do
      assoc = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])
      assoc.user = user
      assoc.save!
      result = authenticator.after_authenticate(auth_token)
      expect(result.user.reload.groups).to include(state_group)
    end

    it "passes the claim on to account creation" do
      result = authenticator.after_authenticate(auth_token)
      expect(result.extra_data[:groups]).to eq(["Piratenpartei Deutschland", "Hessen"])

      authenticator.after_create_account(user, extra_data: result.extra_data)
      expect(user.reload.groups).to include(state_group)
    end

    it "drops the Landesverband group when the required role is gone" do
      assoc = UserAssociatedAccount.find_or_initialize_by(provider_name: auth_token[:provider], provider_uid: auth_token[:uid])
      assoc.user = user
      assoc.save!
      state_group.add(user)
      auth_token[:extra][:raw_info][:roles] = []

      authenticator.after_authenticate(auth_token)
      expect(user.reload.groups).not_to include(state_group)
    end
  end
end
