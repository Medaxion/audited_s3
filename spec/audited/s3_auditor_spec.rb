require 'spec_helper'
require 'aws-sdk'

describe 's3 auditor' do
  before do
    Audited.config do |config|
      config.storage_mechanism = :s3
      config.storage_options = {
        bucket_name: ENV['s3_bucket_name'],
        access_key_id: ENV['s3_access_key_id'],
        secret_access_key: ENV['s3_secret_access_key'],
        s3_key_prefix: ENV['s3_key_prefix'],
        stub_responses: true
      }
    end
  end

  after do
    Audited.config do |config|
      config.storage_mechanism = :active_record
    end
  end

  describe 'writing an audit to s3' do
    context 'auditable is not already in s3' do
      it 'should persist it to the s3 bucket' do
        company = Models::ActiveRecord::Company.create

        results = company.audits

        expect(results.count).to eq(1)

        audit = results.first

        expect(audit.auditable_type).to eq(company.class.to_s)
        expect(audit.auditable_id).to eq(company.id)
        expect(audit.action).to eq('create')
        expect(audit.audited_changes).to eq('name' => nil, 'owner_id' => nil)
        expect(audit.version).to eq(1)
        expect(audit.request_uuid).to be_present
        expect(audit.created_at).to be_present
      end
    end

    context 'auditable already has an audit record in s3' do
      it 'should append a new audit to an existing s3 file' do
        company = Models::ActiveRecord::Company.create(
          name: "Willy Wonka's Chocolate Factory"
        )

        company.update_attribute(:name, "Slugworth's Chocolate Factory")

        results = company.audits

        expect(results.count).to eq(2)

        create_audit = results.first
        expect(create_audit.auditable).to eq(company)
        expect(create_audit.action).to eq('create')
        expect(create_audit.audited_changes).to eq('name' => "Willy Wonka's Chocolate Factory", 'owner_id' => nil)
        expect(create_audit.version).to eq(1)
        expect(create_audit.request_uuid).to be_present
        expect(create_audit.created_at).to be_present

        update_audit = results.second
        expect(update_audit.auditable).to eq(company)
        expect(update_audit.action).to eq('update')
        expect(update_audit.audited_changes).to eq('name' => ["Willy Wonka's Chocolate Factory", "Slugworth's Chocolate Factory"])
        expect(update_audit.version).to eq(2)
        expect(update_audit.request_uuid).to be_present
        expect(update_audit.created_at).to be_present
      end
    end

    describe 'writing with restriction modifiers' do
      context 'auditable specifies :except' do
        before do
          class ExclusionCompany < ::ActiveRecord::Base
            self.table_name = 'companies'
            audited except: :owner_id
          end
        end

        it 'should not record changes to that field' do
          company = ExclusionCompany.create(name: 'test', owner_id: 1)

          audit = company.audits.first
          expect(audit.audited_changes['name']).to eq('test')
          expect(audit.audited_changes['owner_id']).to be_nil
        end
      end

      context 'auditable specifies :only' do
        before do
          class InclusionCompany < ::ActiveRecord::Base
            self.table_name = 'companies'
            audited only: :name
          end
        end

        it 'should not record changes to that field' do
          company = InclusionCompany.create(name: 'test', owner_id: 1)

          audit = company.audits.first
          expect(audit.audited_changes['name']).to eq('test')
          expect(audit.audited_changes['owner_id']).to be_nil
        end
      end

      context 'auditable specifies :on' do
        before do
          class OnDeleteCompany < ::ActiveRecord::Base
            self.table_name = 'companies'
            audited on: [:destroy]
          end
        end

        it 'should only record an audit on the delete action' do
          company = OnDeleteCompany.create(name: 'test', owner_id: 1)
          company.destroy

          audits = company.audits
          destroy_audit = audits.first
          expect(audits.count).to eq(1)
          expect(destroy_audit.action).to eq('destroy')
        end
      end

      context 'auditable overrides audited_attributes' do
        it 'should record the specified audited_attributes' do
          company = Models::ActiveRecord::Company.create(name: 'test')
          customer = Models::ActiveRecord::CustomAuditedCustomer.create(company: company, name: 'Grandpa Joe')

          audits = customer.audits
          create_audit = audits.first

          expect(audits.count).to eq(1)

          expect(create_audit.audited_changes['custom']).to eq('value')
          expect(create_audit.audited_changes['company']).to eq(company)
        end
      end
    end
  end

  describe 'writing an associated audit to s3' do
    context 'auditable is not already in s3' do
      it 'should write the associated audit to s3' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
        employee = company.employees.create(name: 'Charlie Bucket')

        results = employee.audits

        expect(results.count).to eq(1)

        employee_audit = results.first
        expect(employee_audit.auditable_id).to eq(employee.id)
        expect(employee_audit.auditable_type).to eq('Models::ActiveRecord::Employee')
        expect(employee_audit.action).to eq('create')
        expect(employee_audit.audited_changes).to eq('company_id' => company.id, 'name' => 'Charlie Bucket')
        expect(employee_audit.version).to eq(1)
        expect(employee_audit.request_uuid).to be_present
        expect(employee_audit.created_at).to be_present

        expect(employee_audit.associated).to eq(company)
      end
    end

    context 'auditable already has an associated audit record in s3' do
      it 'should increment the version for its auditable_id' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
        employee = company.employees.create(name: 'Charlie Buckett')

        another_employee = company.employees.create(name: 'Oompa Loompa')

        employee.update_attribute(:name, 'Charlie Bucket')

        employee_audits = employee.audits

        expect(employee_audits.count).to eq(2)

        create_audit = employee_audits.first
        # TODO: why isn't this getting set?
        # expect(create_audit.auditable).to eq(employee)
        expect(create_audit.action).to eq('create')
        expect(create_audit.audited_changes).to eq('company_id' => company.id, 'name' => 'Charlie Buckett')
        expect(create_audit.version).to eq(1)
        expect(create_audit.request_uuid).to be_present
        expect(create_audit.created_at).to be_present
        expect(create_audit.associated).to eq(company)

        update_audit = employee_audits.second
        # expect(update_audit.auditable).to eq(employee)
        expect(update_audit.action).to eq('update')
        expect(update_audit.audited_changes).to eq('name' => ['Charlie Buckett', 'Charlie Bucket'])
        expect(update_audit.version).to eq(2)
        expect(update_audit.request_uuid).to be_present
        expect(update_audit.created_at).to be_present
        expect(update_audit.associated).to eq(company)
      end
    end
  end

  describe 'partitioning audits' do
    context "partitioning is ON" do
      before do
        Audited.config do |config|
          config.storage_options = {
            bucket_name: ENV['s3_bucket_name'],
            access_key_id: ENV['s3_access_key_id'],
            secret_access_key: ENV['s3_secret_access_key'],
            s3_key_prefix: 'test',
            partition: true,
            stub_responses: true
          }
        end
      end

      it "should store types in a batched range folder" do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factory')
        audit = company.audits.first

        expect(audit.s3_key).to eq("test/auditable_type_audits/models/active_record/company/0_9999/#{company.id}.audits")
      end

      it 'should not partition types marked as unpartitioned' do
        Audited.storage_options[:unpartitioned_types] = ['Models::ActiveRecord::Company']

        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factory')
        audit = company.audits.first

        expect(audit.s3_key).to eq("test/auditable_type_audits/models/active_record/company/#{company.id}.audits")
      end
    end

    context "partitioning is OFF" do
      before do
        Audited.config do |config|
          config.storage_options = {
            bucket_name: ENV['s3_bucket_name'],
            access_key_id: ENV['s3_access_key_id'],
            secret_access_key: ENV['s3_secret_access_key'],
            s3_key_prefix: 'test',
            partition: false,
            stub_responses: true
          }
        end
      end

      it 'should store the audits in an unpartitioned directory' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factory')
        audit = company.audits.first

        expect(audit.s3_key).to eq("test/auditable_type_audits/models/active_record/company/#{company.id}.audits")
      end
    end
  end

  describe 'association methods' do
    describe 'auditor.audits' do
      it 'should retrieve the audits' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attribute(:name, 'Willy Wonka Factor')
        company.update_attribute(:name, 'Willy Wonka Factory')

        results = company.audits

        expect(results.count).to eq(3)

        first = results.first

        expect(first.auditable_type).to eq(company.class.to_s)
        expect(first.auditable_id).to eq(company.id)
        expect(first.action).to eq('create')
        expect(first.audited_changes).to eq('name' => 'Willy Wonk Factor', 'owner_id' => nil)
        expect(first.version).to eq(1)
        expect(first.request_uuid).to be_present
        expect(first.created_at).to be_present

        second = results.second
        expect(second.auditable_type).to eq(company.class.to_s)
        expect(second.auditable_id).to eq(company.id)
        expect(second.action).to eq('update')
        expect(second.audited_changes).to eq('name' => ['Willy Wonk Factor', 'Willy Wonka Factor'])
        expect(second.version).to eq(2)
        expect(second.request_uuid).to be_present
        expect(second.created_at).to be_present

        third = results.third
        expect(third.auditable_type).to eq(company.class.to_s)
        expect(third.auditable_id).to eq(company.id)
        expect(third.action).to eq('update')
        expect(third.audited_changes).to eq('name' => ['Willy Wonka Factor', 'Willy Wonka Factory'])
        expect(third.version).to eq(3)
        expect(third.request_uuid).to be_present
        expect(third.created_at).to be_present
      end

      it 'should retrieve the associated_audits' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
        employee = company.employees.create(name: 'Charlie Bucket')

        associated_audits = company.associated_audits

        expect(associated_audits.count).to eq(1)

        employee_audit = associated_audits.first

        expect(employee_audit.auditable_type).to eq(employee.class.to_s)
        expect(employee_audit.auditable_id).to eq(employee.id)
        expect(employee_audit.associated_type).to eq(company.class.to_s)
        expect(employee_audit.associated_id).to eq(company.id)
        expect(employee_audit.action).to eq('create')
        expect(employee_audit.audited_changes).to \
          eq('company_id' => company.id, 'name' => 'Charlie Bucket')
        expect(employee_audit.version).to eq(1)
        expect(employee_audit.request_uuid).to be_present
        expect(employee_audit.created_at).to be_present
      end

      context 'no audits exist' do
        it 'should return an empty array' do
          company = Models::ActiveRecord::Company.new
          expect(company.audits.to_a).to eq([])
        end
      end

      context 'id is not present on auditor' do
        it 'should return an empty array' do
          employee = Models::ActiveRecord::Employee.new(name: 'Charlie Bucket')
          employee.company = Models::ActiveRecord::Company.new(name: 'Willy Wonka Factory')

          audits = employee.audits.from('')
          expect(audits.to_a).to eq([])
        end
      end
    end

    describe 'auditor.audits.create' do
      it 'should persist the audit to S3' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.audits.create(action: 'custom update', audited_changes: { 'name' => 'Willy Wonka Factory' })

        results = company.audits

        expect(results.count).to eq(2)

        custom_audit = results.second
        expect(custom_audit.auditable_type).to eq(company.class.to_s)
        expect(custom_audit.auditable_id).to eq(company.id)
        expect(custom_audit.action).to eq('custom update')
        expect(custom_audit.audited_changes).to eq('name' => 'Willy Wonka Factory')
        expect(custom_audit.version).to eq(2)
        expect(custom_audit.request_uuid).to be_present
        expect(custom_audit.created_at).to be_present
      end
    end

    describe 'auditor.audits.descending' do
      it 'should sort them by the largest to smallest versions' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        audit_versions = company.audits.descending.map(&:version)

        expect(audit_versions).to eq([3, 2, 1])
      end
    end

    describe 'auditor.audits.ascending' do
      it 'should sort them by the smallest to largest versions' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        audit_versions = company.audits.ascending.map(&:version)

        expect(audit_versions).to eq([1, 2, 3])
      end
    end

    describe 'auditor.audits.detect' do
      it 'should be able to retrieve a specific audit' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        create_audit = company.audits.detect { |audit| audit.action == 'create' }

        expect(create_audit.action).to eq('create')
      end
    end

    describe 'auditor.audits.exists?' do
      it 'should return true when criterion are met' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        has_updates = company.audits.exists?(action: 'update', version: 2)
        expect(has_updates).to be true
      end

      it 'should return false when one or more conditions are not met' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        has_updates = company.audits.exists?(action: 'update', version: 1)
        expect(has_updates).to be false
      end
    end

    describe 'auditor.audits.find_by' do
      it 'should return the first matching record when a record matches the criteria' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')
        company.update_attributes(name: 'Willy Wonka Factor')

        create_audit = company.audits.find_by(action: 'create')
        expect(create_audit).to be_present
        expect(create_audit.action).to eq('create')
      end
    end

    describe 'auditor.audits.where' do
      it 'should return the records that match the criteria' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')
        company.update_attributes(name: 'Willy Wonka Factor')
        company.update_attributes(name: 'Willy Wonka Factory')

        matching_audits = company.audits.where(action: 'update')
        expect(matching_audits.count).to eq(2)
        expect(matching_audits.first.action).to eq('update')
        expect(matching_audits.second.action).to eq('update')
      end

      it 'should return an empty array when no records match the criteria' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')

        matching_audits = company.audits.where(action: 'destroy')
        expect(matching_audits).to eq([])
      end
    end

    describe 'auditor.own_and_associated_audits' do
      context 'own and associated audits exist' do
        it 'should return results sorted by created_at desc' do
          company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
          employee = company.employees.create(name: 'Charlie Bucket')

          audits = company.own_and_associated_audits
          expect(audits.count).to eq(2)

          first_audit = audits.first
          second_audit = audits.second
          expect(first_audit.auditable_type).to eq(employee.class.name)
          expect(second_audit.auditable_type).to eq(company.class.name)
        end
      end

      context 'only own audits exist' do
        it 'should return its own audits sorted by created_at desc' do
          company = Models::ActiveRecord::Company.create(name: 'Willy Wonk Factor')
          company.update_attributes(name: 'Willy Wonka Factory')

          audits = company.own_and_associated_audits
          expect(audits.count).to eq(2)

          first_audit = audits.first
          second_audit = audits.second

          expect(first_audit.action).to eq('update')
          expect(first_audit.auditable_type).to eq(company.class.name)
          expect(second_audit.action).to eq('create')
          expect(second_audit.auditable_type).to eq(company.class.name)
        end
      end
    end
  end

  describe 'stubbing responses' do
    before do
      Audited.config do |config|
        config.storage_options = {
          bucket_name: ENV['s3_bucket_name'],
          access_key_id: ENV['s3_access_key_id'],
          secret_access_key: ENV['s3_secret_access_key'],
          s3_key_prefix: ENV['s3_key_prefix'],
          stub_responses: true
        }
      end
    end

    it 'should stub get_object and put_object calls' do
      company = Models::ActiveRecord::Company.new(name: 'Willy Wonk Factor')

      s3_auditor = Audited::S3Auditor.new(
        storage_options: Audited.storage_options,
        auditor: company
      )

      audit = company.audits.new(comment: 'first audit')
      s3_key = s3_auditor.resolve_s3_key(audit)
      s3_auditor.write_audit(audit)

      audit2 = company.audits.new(comment: 'second audit')
      s3_auditor.write_audit(audit2)

      response = s3_auditor.read_audits(s3_key)

      expect(response.first.comment).to eq('first audit')
      expect(response.second.comment).to eq('second audit')

      audit_body = Audited::S3Auditor.s3_stub_cache[s3_key]
      expect(audit_body).not_to be(nil)
    end
  end

  describe 'up_until' do
    it 'should return audits on or before the specified date' do

      Timecop.freeze '2018-01-01 05:30'
      company = Models::ActiveRecord::Company.create(name: 'Willy')

      Timecop.freeze '2018-02-01 05:30'
      company.update_attributes(name: 'Willy Wonka')

      Timecop.freeze '2018-03-01 05:30'
      company.update_attributes(name: 'Willy Wonka Factory')

      matching_audits = company.audits.up_until('2018-02-01 05:30')

      matching_audits.each do |audit|
        expect(audit.created_at).to be <= '2018-02-01 05:30'
      end
    end
  end

  describe 'revision_at' do
    it 'should reconstruct the object state based on the specified state' do
      Timecop.freeze '2018-01-01 05:30'
      company = Models::ActiveRecord::Company.create(name: 'Willy')

      Timecop.freeze '2018-02-01 05:30'
      company.update_attributes(name: 'Willy Wonka')

      Timecop.freeze '2018-03-01 05:30'
      company.update_attributes(name: 'Willy Wonka Factory')

      revision_at = company.revision_at('2018-02-01 05:30')
      expect(revision_at.name).to eq('Willy Wonka')

      revision_at = company.revision_at('2018-07-01')
      expect(revision_at.name).to eq('Willy Wonka Factory')
    end
  end

  describe 'reading audits from s3' do
    context 'audits exist in auditable and associated locations' do
      let(:company) { Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory') }
      let(:employee) { Models::ActiveRecord::Employee.create(name: 'Charlie Bucket') }
      let!(:cache) { Audited::S3Auditor.s3_stub_cache }

      before do
        employee.update_attributes(company: company)
      end

      it 'should be able to retrieve the employee audit before it was associated with the company' do
        employee_created = employee.audits.first
        expect(employee_created.auditable).to eq(employee)
        expect(employee_created.associated).to be(nil)
      end

      it 'should pull from both locations' do
        employee_updated = employee.audits.second
        expect(employee_updated.auditable).to eq(employee)
        expect(employee_updated.associated).to eq(company)
      end
    end
  end
end