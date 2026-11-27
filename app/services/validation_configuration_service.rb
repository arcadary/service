require "tempfile"

class ValidationConfigurationService
  attr_reader :storage_path

  def initialize(env: ENV, environment: Rails.env, root: Rails.root)
    @env = env
    @environment = environment.to_s
    @root = Pathname.new(root)
  end

  def check!
    default_enabled = %w[development test].include?(@environment) ? "true" : "false"
    raise ValidationSubmission::Unavailable unless @env.fetch("VALIDATION_UPLOADS_ENABLED", default_enabled) == "true"
    raise ValidationSubmission::Unavailable if %w[VALIDATION_REVIEWER_USERNAME VALIDATION_REVIEWER_PASSWORD].any? { |key| @env[key].to_s.strip.empty? }

    configure_path!
    probe_storage!
    self
  rescue SystemCallError, IOError, ArgumentError
    raise ValidationSubmission::Unavailable
  end

  private
    def configure_path!
      default_path = @environment == "test" ? @root.join("tmp/validations-#{Process.pid}") : @root.join("storage/validations")
      path = Pathname.new(@env.fetch("VALIDATION_STORAGE_PATH", @environment == "production" ? "" : default_path.to_s).to_s)
      raise ValidationSubmission::Unavailable unless path.absolute?

      path = path.cleanpath
      ancestor = path
      ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
      resolved = ancestor.realpath.join(path.relative_path_from(ancestor)).cleanpath
      if @environment == "production"
        volume = @root.join("storage").realpath
        raise ValidationSubmission::Unavailable unless descendant?(resolved, volume)
      end
      public_path = @root.join("public").realpath
      raise ValidationSubmission::Unavailable if resolved == public_path || descendant?(resolved, public_path)

      FileUtils.mkdir_p(path, mode: 0o700)
      @storage_path = path.realpath
      raise ValidationSubmission::Unavailable unless @storage_path == resolved && @storage_path.directory? && @storage_path.stat.owned?
      File.chmod(0o700, @storage_path)
    end

    def descendant?(path, parent)
      path.to_s.start_with?("#{parent}/")
    end

    def probe_storage!
      Tempfile.create([ ".probe-", "" ], @storage_path) do |file|
        file.write("probe")
        file.flush
        file.fsync
      end
    end
end
