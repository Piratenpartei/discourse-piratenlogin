# frozen_string_literal: true

require 'rails_helper'
require_relative '../../lib/piratenlogin_group_sync'

describe PiratenloginGroupSync do
  let(:user) { Fabricate(:user) }
  # The forum names its Landesverband groups after the state; full_name is
  # decorative and does not have to line up with anything.
  let!(:hessen) { Fabricate(:group, name: 'Hessen', full_name: 'Hessische Piraten') }
  let!(:bayern) { Fabricate(:group, name: 'Bayern', full_name: 'Bayern Piraten') }

  before do
    SiteSetting.piratenlogin_group_sync_enabled = true
    SiteSetting.piratenlogin_groups_claim = 'groups'
    SiteSetting.piratenlogin_group_parent_path = '/Worldwide'
    SiteSetting.piratenlogin_group_mapping = "HE|Hessen\nBY|Bayern"
  end

  describe '.claim_values' do
    it 'reads the configured claim through either key' do
      expect(described_class.claim_values(groups: ['/Worldwide/HE'])).to eq(['/Worldwide/HE'])
      expect(described_class.claim_values('groups' => ['/Worldwide/HE'])).to eq(['/Worldwide/HE'])
    end

    it 'wraps a single value' do
      expect(described_class.claim_values(groups: '/Worldwide/HE')).to eq(['/Worldwide/HE'])
    end

    it 'distinguishes a missing claim from an empty one' do
      # The realm's own `roles` claim carries realm roles, not groups; a token
      # with only that must not read as "member of nothing".
      expect(described_class.claim_values(roles: ['Piratenpartei Deutschland'])).to be_nil
      expect(described_class.claim_values(groups: [])).to eq([])
      expect(described_class.claim_values(nil)).to be_nil
    end
  end

  describe '.candidate_names' do
    it 'takes every segment below the parent' do
      expect(described_class.candidate_names('/Worldwide/HE')).to eq(['HE'])
      expect(described_class.candidate_names('/Worldwide/HE/KV Kassel')).to eq(['HE', 'KV Kassel'])
    end

    it 'accepts a bare group name, for a mapper without full paths' do
      expect(described_class.candidate_names('HE')).to eq(['HE'])
    end

    it 'ignores a path outside the parent' do
      expect(described_class.candidate_names('/Elsewhere/HE')).to eq([])
      expect(described_class.candidate_names('/Worldwide')).to eq([])
    end

    it 'accepts any path when no parent is configured' do
      SiteSetting.piratenlogin_group_parent_path = ''
      expect(described_class.candidate_names('/Elsewhere/HE')).to eq(['Elsewhere', 'HE'])
    end
  end

  describe '.sync!' do
    it 'maps the Keycloak group onto the forum group' do
      described_class.sync!(user, ['/Worldwide/HE'])
      expect(user.reload.groups).to include(hessen)
      expect(user.groups).not_to include(bayern)
    end

    it 'resolves a bare group name too' do
      described_class.sync!(user, ['HE'])
      expect(user.reload.groups).to include(hessen)
    end

    it 'resolves a target that only matches a full name' do
      SiteSetting.piratenlogin_group_mapping = 'HE|Hessische Piraten'
      described_class.sync!(user, ['/Worldwide/HE'])
      expect(user.reload.groups).to include(hessen)
    end

    it 'moves the user when the Landesverband changes' do
      hessen.add(user)
      described_class.sync!(user, ['/Worldwide/BY'])
      expect(user.reload.groups).to include(bayern)
      expect(user.groups).not_to include(hessen)
    end

    it 'is a no-op when the claim is missing' do
      hessen.add(user)
      described_class.sync!(user, nil)
      expect(user.reload.groups).to include(hessen)
    end

    it 'removes every mapped group when the claim is empty' do
      hessen.add(user)
      described_class.sync!(user, [])
      expect(user.reload.groups).not_to include(hessen)
    end

    it 'does nothing while the setting is off' do
      SiteSetting.piratenlogin_group_sync_enabled = false
      described_class.sync!(user, ['/Worldwide/HE'])
      expect(user.reload.groups).not_to include(hessen)
    end

    it 'ignores a group that is not mapped' do
      other = Fabricate(:group, name: 'Berlin', full_name: 'Berliner Piraten')
      described_class.sync!(user, ['/Worldwide/BE'])
      expect(user.reload.groups).not_to include(other)
    end

    it 'skips a mapped state whose group does not exist' do
      SiteSetting.piratenlogin_group_mapping = "HE|Hessen\nSL|Saarland"
      expect { described_class.sync!(user, ['/Worldwide/SL']) }.not_to raise_error
      expect(user.reload.groups).to be_empty
    end

    it 'never touches an automatic group even when it is mapped' do
      staff = Group.find(Group::AUTO_GROUPS[:staff])
      SiteSetting.piratenlogin_group_mapping = "HE|#{staff.name}"
      described_class.sync!(user, ['/Worldwide/HE'])
      expect(user.reload.groups).not_to include(staff)
    end
  end

  describe '.revoke!' do
    it 'drops every managed group' do
      hessen.add(user)
      described_class.revoke!(user)
      expect(user.reload.groups).not_to include(hessen)
    end
  end
end
