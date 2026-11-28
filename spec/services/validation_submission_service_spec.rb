require "rails_helper"
require_relative "../support/validation_helpers"

RSpec.describe ValidationSubmissionService do
  self.use_transactional_tests = false
  include_context "private validation storage"

  before { ValidationSubmission.delete_all }
  after { ValidationSubmission.delete_all }

  def service
    described_class.new(configuration: @receipt_configuration.check!)
  end

  def admit
    service.admit(sha1: checksum, byte_size: payload.bytesize, system: "c64").fetch(:admission)
  end

  it "serializes concurrent admissions into one row with fresh usable tokens" do
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { admit }
      end
    end
    tokens = workers.map(&:value)
    expect(tokens.uniq.size).to eq(2)
    expect(ValidationSubmission.count).to eq(1)
    expect(Dir.children(@receipt_folder)).to eq([ "#{checksum}.lock" ])
  ensure
    workers&.each(&:join)
  end

  it "recovers abandoned staging on the next eligible upload without treating it as complete" do
    token = admit
    staging = File.join(@receipt_folder, "#{checksum}.stage")
    File.write(staging, "abandoned partial", mode: "wb", perm: 0o600)
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(File.exist?(File.join(@receipt_folder, "#{checksum}.data"))).to be(false)
    expect(service.receive(sha1: checksum, admission: token, length: payload.bytesize, body: StringIO.new(payload))).to eq(status: "received")
    expect(File.exist?(staging)).to be(false)
    expect(File.binread(File.join(@receipt_folder, "#{checksum}.data"))).to eq(payload)
    expect(ValidationSubmission.sole.completed_at).to be_present
  end

  it "preserves an active process's staging while a concurrent retry waits for checksum ownership" do
    token = admit
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    ActiveRecord::Base.connection_pool.disconnect!
    child = fork do
      ready_reader.close
      release_writer.close
      ActiveRecord::Base.connection_pool.disconnect!
      body = StringIO.new(payload)
      waiting_body = Object.new
      waiting_body.define_singleton_method(:read) do |length|
        chunk = body.read(length)
        unless chunk
          ready_writer.write("ready")
          ready_writer.flush
          release_reader.read(1)
        end
        chunk
      end
      begin
        service.receive(sha1: checksum, admission: token, length: payload.bytesize, body: waiting_body)
        Process.exit!(0)
      rescue StandardError
        Process.exit!(1)
      end
    end
    ready_writer.close
    release_reader.close
    Timeout.timeout(5) { expect(ready_reader.read(5)).to eq("ready") }
    staging = File.join(@receipt_folder, "#{checksum}.stage")
    inode = File.stat(staging).ino
    started = Queue.new
    retry_body = double("completed retry body")
    expect(retry_body).not_to receive(:read)
    contender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        service.receive(sha1: checksum, admission: token, length: payload.bytesize, body: retry_body)
      end
    end
    started.pop
    expect(contender.join(0.05)).to be_nil
    expect(File.stat(staging).ino).to eq(inode)
    expect(ValidationSubmission.sole.completed_at).to be_nil
    release_writer.write("x")
    release_writer.close
    Timeout.timeout(5) { expect(contender.value).to eq(status: "received") }
    _, status = Process.wait2(child)
    child = nil
    expect(status).to be_success
    expect(ValidationSubmission.count).to eq(1)
    expect(Dir.children(@receipt_folder).sort).to eq([ "#{checksum}.data", "#{checksum}.lock" ])
    expect(File.binread(File.join(@receipt_folder, "#{checksum}.data"))).to eq(payload)
  ensure
    release_writer&.close unless release_writer&.closed?
    if child
      Process.kill("TERM", child) rescue Errno::ESRCH
      Process.wait(child) rescue Errno::ECHILD
    end
    contender&.kill if contender&.alive?
    contender&.join
    [ ready_reader, ready_writer, release_reader, release_writer ].compact.each { |io| io.close unless io.closed? }
    ActiveRecord::Base.connection_pool.disconnect!
  end
end
