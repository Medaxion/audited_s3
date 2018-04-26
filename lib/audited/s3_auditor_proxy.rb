class S3AuditorProxy
  attr_reader :auditor
  attr_writer :deferred_action

  def initialize(auditor)
    @auditor = auditor
    @s3_auditor = Audited::S3Auditor.new(
      storage_options: Audited.storage_options,
      auditor: auditor
    )
  end

  def method_missing(meth, *args, &block)
    if meth == :new
      new_audit(args.first)
    elsif [].respond_to?(meth)
      run_deferred_action(meth, *args, &block) if @deferred_action.present?
    else
      super
    end
  end

  def respond_to?(method, *)
    [].respond_to?(method)
  end

  def create(audit_attrs)
    audit = new_audit(audit_attrs)
    @s3_auditor.write_audit(audit)
  end

  def new_audit(audit_attrs)
    @auditor.method(:audits).super_method.call.new(audit_attrs)
  end

  def audits
    @deferred_action = 'retrieve_audits_from_s3'
    self
  end

  def associated_audits
    @deferred_action = 'retrieve_associated_audits_from_s3'
    self
  end

  def own_and_associated_audits
    own = retrieve_audits_from_s3.to_a
    associated = retrieve_associated_audits_from_s3.to_a

    (own + associated).sort_by(&:created_at).reverse
  end


  def ascending
    audits = send(@deferred_action)
    audits.sort_by(&:version)
  end

  def descending
    ascending.reverse
  end

  def exists?(criteria)
    audits = send(@deferred_action)
    audits.any? { |audit| audit_meets_criteria?(audit, criteria) }
  end

  def find_by(criteria)
    audits = send(@deferred_action)
    audits.detect { |audit| audit_meets_criteria?(audit, criteria) }
  end

  def where(criteria)
    audits = send(@deferred_action)
    audits.select { |audit| audit_meets_criteria?(audit, criteria) }
  end

  def up_until(date_or_time)
    audits = retrieve_audits_from_s3
    @s3_auditor.up_until(audits, date_or_time)
  end

  def from(_)
    self
  end

  private

  def audit_meets_criteria?(audit, criteria)
    results = criteria.map do |attribute, value|
      audit.send(attribute) == value
    end

    results.all?
  end

  def run_deferred_action(meth, *args, &block)
    send(@deferred_action).send(meth, *args, &block)
  end

  # Audits can exist in two locations. For example, let's say an employee can
  # be associated with a company but doesn't have to be. On creation, the employee
  # doesn't belong to a company, but later on the employee gets assigned to it.
  # In such a case, we'd have two audit files we need to read from:
  # 1. auditable_type_audits/employee/1.audits
  # 2. associated_type_audits/company/1.audits
  def retrieve_audits_from_s3
    [].tap do |results|
      auditable_audit = new_audit({})
      auditable_s3_key = @s3_auditor.resolve_s3_key(auditable_audit)
      results.concat(@s3_auditor.read_audits(auditable_s3_key, auditable_audit.auditable))

      unless @auditor.audit_associated_with.nil?
        associated_audit_attrs = { associated: @auditor.send(@auditor.audit_associated_with) }
        associated_audit = new_audit(associated_audit_attrs)
        associated_s3_key = @s3_auditor.resolve_s3_key(associated_audit)
        results.concat(@s3_auditor.read_audits(associated_s3_key, associated_audit.auditable))
      end
    end
  end

  def retrieve_associated_audits_from_s3
    audit_attrs = {}
    audit = new_audit(audit_attrs)
    audit.associated = auditor

    s3_key = @s3_auditor.resolve_s3_key(audit)

    @s3_auditor.read_audits(s3_key)
  end
end
