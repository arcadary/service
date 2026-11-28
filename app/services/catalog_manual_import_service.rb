class CatalogManualImportService
  def self.call(path:, preview: false)
    envelope = JSON.parse(File.read(path, encoding: "UTF-8"))
    fields = preview ? %w[operation attributes] : %w[operation attributes expected_revisions reason idempotency_key preview]
    unless envelope.is_a?(Hash) && (envelope.keys - fields).empty?
      raise CatalogAuthoringService::InvalidInput, "expected one operation envelope with supported fields"
    end
    required = preview ? fields : fields - [ "preview" ]
    unless (required - envelope.keys).empty?
      raise CatalogAuthoringService::InvalidInput, "missing envelope fields: #{(required - envelope.keys).join(', ')}"
    end

    if preview
      CatalogAuthoringService.preview(operation: envelope.fetch("operation"), attributes: envelope.fetch("attributes"))
    else
      CatalogAuthoringService.call(**envelope.symbolize_keys)
    end
  end
end
