class PlaythroughStageInputService
  DECLARATION_BYTES = 1.megabyte
  OBJECT_BYTES = 8.megabytes
  PACKAGE_BYTES = 4.gigabytes
  OBJECT_COUNT = 4096

  def self.read(io:, limit:)
    bytes = +"".b
    loop do
      chunk = io.read([ 64.kilobytes, limit + 1 - bytes.bytesize ].min)
      break if chunk.nil? || chunk.empty?

      bytes << chunk
      raise PlaythroughStage::TooLarge if bytes.bytesize > limit
    end
    bytes
  rescue IOError, EOFError, SystemCallError
    raise PlaythroughStage::InterruptedTransfer
  end
end
