require 'spec_helper'
require 'aws-sdk'

describe 's3 audit' do
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

  describe 'audit.update_attributes' do
    context 'audit.associated is nil' do
      it 'should update the specified attributes' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')

        audit = company.audits.first
        audit.update_attributes(action: 'update')

        refreshed_audit = company.audits.first
        expect(refreshed_audit.action).to eq('update')
      end
    end

    context 'audit.associated is present' do
      it 'should update the specified attributes' do
        company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
        employee = company.employees.create(name: 'Charlie Bucket')

        employee_audit = employee.audits.first
        employee_audit.update_attributes(action: 'update test')

        refreshed_audit = employee.audits.first

        expect(refreshed_audit.action).to eq('update test')
      end
    end

    describe 'moving an audit from auditable -> associated' do
      let!(:company) { Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory') }
      let!(:employee) { Models::ActiveRecord::Employee.create(name: 'Charlie Bucket') }
      let!(:cache) { Audited::S3Auditor.s3_stub_cache }

      def employee_created_audit
        employee.audits.find_by(action: 'create')
      end

      before do
        company.update_attributes(employees: [employee])
        @old_s3_key = employee_created_audit.s3_key
        employee_created_audit.try(:update, associated: company)
        @new_s3_key = employee_created_audit.s3_key
      end

      it 'should delete the audit from the auditable location' do
        expect(cache[@old_s3_key]).to be(nil)
      end

      it 'should create an entry in the associated location' do
        expect(cache[@new_s3_key]).to be_present
      end

      it 'should be able to retrieve the audit' do
        expect(employee.audits.to_a).to include(employee_created_audit)
      end
    end
  end

  describe 'audit.update_column' do
    it 'should update the column' do
      company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')

      audit = company.audits.first
      audit.update_attributes(action: 'update')

      refreshed_audit = company.audits.first
      expect(refreshed_audit.action).to eq('update')
    end
  end

  describe 'audit.create' do
    it 'be retrievable after persistance' do
      company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
      audit = Audited::Audit.create(auditable: company, action: 'update')

      output = company.audits.last
      expect(output.auditable).to eq(company)
      expect(output.action).to eq('update')
      expect(output.version).to eq(2)
    end

    describe 'created_at' do
      context 'created_at not specified' do
        it 'should set audit.created_at = current time' do
          Timecop.freeze '2018-06-20 05:34' do
            company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
            Audited::Audit.create(auditable: company)

            expect(company.audits.last.created_at).to eq('2018-06-20 05:34')
          end
        end
      end

      context 'created_at specified' do
        it 'should set audit.created_at to the specified time' do
          company = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
          Audited::Audit.create(auditable: company, created_at: '2018-06-17 05:34')

          expect(company.audits.last.created_at).to eq('2018-06-17 05:34')
        end
      end
    end
  end

  describe 'Audit.count' do
    before do
      Audited::Audit.destroy_all

      @wonka = Models::ActiveRecord::Company.create(name: 'Willy Wonka Factory')
      @charlie = Models::ActiveRecord::Employee.create(name: 'Charlie Bucket', company: @wonka)

      @gump = Models::ActiveRecord::Company.create(name: 'Bubba Gump')
      @forrest = Models::ActiveRecord::Employee.create(name: 'Forrest Gump', company: @gump)

      @gump.update_attributes(name: "Bubba Gump Shrimp Company")

      @bubba = Models::ActiveRecord::Employee.create(name: 'Benjamin Buford Blue')
      @gump.update_attributes(employees: [@forrest, @bubba])
    end

    it 'should retrieve the count' do
      expect(Audited::Audit.count).to eq(7)
    end

    context 'specifying criterion' do
      it 'should retrieve the count for the audits that match the criterion' do
        expect(Audited::Audit.count(auditable_type: 'Models::ActiveRecord::Employee', associated: @wonka)).to eq(1)
      end
    end
  end
end