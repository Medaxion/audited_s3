class S3AuditProxy
  attr_reader :audit

  delegate :update, to: :update_attributes

  def initialize(audit)
    @audit = audit
    @s3_auditor = Audited::S3Auditor.new(
      storage_options: Audited.storage_options,
      auditor: audit.auditable
    )
  end

  def update_column(column_name, value)
    audit_attrs = {}
    audit_attrs[column_name] = value

    update_attributes(audit_attrs)
  end

  def update_attributes(audit_attrs)
    @s3_auditor.modify_audit(@audit, audit_attrs)
  end

  def create
    @s3_auditor.write_audit(@audit)
    @audit
  end

  def self.stubs_count(criterion=nil)
    cache = Audited::S3Auditor.s3_stub_cache
    audits_json = cache.values.flatten.map do |json|
      JSON.parse("[#{json}]")
    end.flatten

    audits = audits_json.map { |json| Audited::Audit.new(json) }

    return audits.count if criterion.blank?

    matches = audits.select do |audit|
      results = criterion.map do |attribute, value|
        audit.send(attribute) == value
      end

      results.all?
    end

    matches.count
  end
  def s3_key
    @s3_auditor.resolve_s3_key(@audit)
  end
end