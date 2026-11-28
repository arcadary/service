class UploadFileDecorator
  def self.decorate(file)
    new(file)
  end

  def initialize(file)
    @file = file
  end

  def as_json(*)
    { "name" => @file.name, "size" => @file.byte_size, "sha256" => @file.sha256 }
  end
end
