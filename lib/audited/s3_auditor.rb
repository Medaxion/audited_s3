require 'aws-sdk'

module Audited
  class S3Auditor
    delegate :auditable_id, to: :auditor
    delegate :auditable_type, to: :auditor

    attr_reader :auditor

    @s3_stub_cache = {}

    class << self
      attr_accessor :s3_stub_cache
    end

    def initialize(storage_options: {}, auditor:)
      validate_storage_options(storage_options)
      @bucket_name = storage_options[:bucket_name]
      @region = storage_options[:region] || 'us-east-1'
      @access_key_id = storage_options[:access_key_id]
      @s3_key_prefix = storage_options[:s3_key_prefix]
      @secret_access_key = storage_options[:secret_access_key]
      @unpartitioned_types = storage_options[:unpartitioned_types]
      @partition = storage_options[:partition]
      @stub_responses = storage_options[:stub_responses] || false

      @auditor = auditor
    end

    def write_audit(audit)
      # not the prettiest in the world, but unfortunately Active Record doesn't
      # expose its internal method for setting the timestamp.
      if audit.created_at.nil?
        audit.created_at = audit.send(:current_time_from_proper_timezone)
      end

      audit.run_s3_callbacks

      s3_key = resolve_s3_key(audit)

      if s3_file_exists?(s3_key)
        audits_in_file = read_audits(s3_key)

        audit.version = new_audit_version(
          audits_for_auditable(audits_in_file)
        )
        audits = audits_in_file.push(audit)
      else
        audit.version = 1
        audits = [audit]
      end

      s3_response = s3_client.put_object(
        bucket: @bucket_name,
        key: resolve_s3_key(audit),
        body: json_formatted_audits(audits)
      )

      { s3_key: s3_key, s3_response: s3_response }
    end

    # NOTE! This isn't a good idea. You really should never modify audits except
    # in the event that the audit was written incorrectly or you are needing to go
    # back and backfill data that was missing.
    def modify_audit(audit, audit_attrs)
      # if the associated reference has changed, we need to delete the audit
      # from the old location so it gets properly moved to the new one
      if audit_attrs[:associated]
        move_audit(audit, audit_attrs)
      else
        s3_key = resolve_s3_key(audit)
        audits = read_audits(s3_key)
        audit_to_modify = audits.detect { |a| a == audit }
        audit_to_modify.assign_attributes(audit_attrs)

        put_audits(s3_key, audits)
      end
    end

    def move_audit(audit, audit_attrs)
      delete_audit(audit)
      audit.assign_attributes(audit_attrs)
      s3_key = resolve_s3_key(audit)
      audits = read_audits(s3_key)
      audits.push(audit)

      put_audits(s3_key, audits)
    end

    def delete_audit(audit)
      s3_key = resolve_s3_key(audit)
      audits = read_audits(s3_key)
      audits.delete(audit)

      if audits.empty?
        s3_client.delete_object(
          bucket: @bucket_name,
          key: s3_key,
        )
      else
        s3_client.put_object(
          bucket: @bucket_name,
          key: s3_key,
          body: json_formatted_audits(audits)
        )
      end
    end

    def read_audits(s3_key, auditable=nil)
      s3_response = s3_client.get_object(
        bucket: @bucket_name,
        key: s3_key
      )

      # NOTE: this is a hack to coerce the new line separated strings that
      # Amazon S3 + Athena expects into a plain old JSON array string that
      # Ruby can parse.
      json_string = '[' + s3_response.body.read + ']'
      json_object = JSON.parse(json_string)

      mapped_audits = json_object.map { |json| audit_from_json(json) }

      if auditable.present?
        audits_for_auditable(mapped_audits)
      else
        mapped_audits
      end
    rescue Aws::S3::Errors::NoSuchKey
      []
    end

    def s3_file_exists?(s3_key)
      s3_resource.bucket(@bucket_name).object(s3_key).exists?
    end

    def resolve_s3_key(audit)
      config = if audit.associated.present?
        { base: 'associated', type: audit.associated_type, id: audit.associated_id }
      else
        { base: 'auditable', type: audit.auditable_type, id: audit.auditable_id }
      end

      key = "#{@s3_key_prefix}/#{config[:base]}_type_audits/#{config[:type].underscore}"

      if should_partition?(config[:type])
        key += "/#{partition_key(config[:id])}"
      end

      key += "/#{config[:id]}.audits"
    end

    def s3_client
      @s3_client ||= Aws::S3::Client.new(
        access_key_id: @access_key_id,
        region: @region,
        secret_access_key: @secret_access_key,
        stub_responses: @stub_responses
      ).tap do |client|
        generate_stubs(client) if @stub_responses
      end
    end

    def s3_resource
      @s3_resource ||= Aws::S3::Resource.new(
        client: s3_client,
        stub_responses: @stub_responses)
    end

    def up_until(audits, date_or_time)
      audits.select { |audit| audit.created_at <= date_or_time }
    end

    private

    def audits_for_auditable(audits)
      audits.select do |a|
        a.auditable_type == auditable_type && a.auditable_id == auditable_id
      end
    end

    def new_audit_version(audits)
      audits.any? ? audits.sort_by(&:version).last.version + 1
                  : 1
    end

    def validate_storage_options(storage_options)
      raise 'bucket_name must be present' unless storage_options.has_key?(:bucket_name)
      raise 'access_key_id must be present' unless storage_options.has_key?(:access_key_id)
      raise 'secret_access_key must be present' unless storage_options.has_key?(:secret_access_key)
    end

    # NOTE: because we're using S3 + Amazon Athena for record storage,
    # we're relying on a new line separator to distinguish between JSON records.
    # Some other formats would rightly expect the JSON string to be stored like
    # a normal JSON array [{...}, {...}]. We should add support for this JSON
    # string representation.
    def json_formatted_audits(audits)
      audits.map(&:to_json).join(",\n")
    end

    def audit_from_json(json)
      Audit.new(json).tap do |a|
        a.created_at = Time.parse("#{json['created_at']} UTC")

        audited_changes = json['audited_changes']
        if audited_changes.is_a?(String) && audited_changes.starts_with?('---')
          a.audited_changes = YAML.load(json['audited_changes'])
        end
      end
    end

    def should_partition?(type)
      is_partitioned_type = (@unpartitioned_types || []).exclude?(type)
      @partition && is_partitioned_type
    end

    def partition_key(id)
      return "?" if id.nil?

      range_start = id / 10000 * 10000
      range_end = range_start + 10000 - 1

      "#{range_start}_#{range_end}"
    end

    def put_audits(s3_key, audits)
      s3_response = s3_client.put_object(
        bucket: @bucket_name,
        key: s3_key,
        body: json_formatted_audits(audits)
      )

      { s3_key: s3_key, s3_response: s3_response }
    end

    def generate_stubs(client)
      client.stub_responses(:get_object, lambda do |context|
        { body: self.class.s3_stub_cache[context.params[:key]] || '' }
      end)

      client.stub_responses(:put_object, lambda do |context|
        body = context.params[:body]
        key = context.params[:key]
        self.class.s3_stub_cache[key] = body
        { etag: '', server_side_encryption: '', version_id: '' }
      end)

      client.stub_responses(:delete_object, lambda do |context|
        self.class.s3_stub_cache.delete(context.params[:key])
        {}
      end)

      client.stub_responses(:head_object, lambda do |context|
        key = context.params[:key]

        status_code = self.class.s3_stub_cache.has_key?(key) ? 200 : 404
        { status_code: status_code, headers: {}, body: ''}
      end)
    end
  end
end
