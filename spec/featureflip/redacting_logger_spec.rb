require "spec_helper"
require "stringio"
require "logger"

RSpec.describe Featureflip::RedactingLogger do
  let(:secret) { "sdk_server_SentinelKeyMustNeverAppearInLogs-0123456789" }
  let(:io) { StringIO.new }
  let(:inner) { Logger.new(io, level: Logger::DEBUG) }
  let(:logger) { described_class.new(inner, secret) }

  it "redacts the key from a string message" do
    logger.warn("Authorization: #{secret}")
    expect(io.string).to include("Authorization: [redacted]")
    expect(io.string).not_to include(secret)
  end

  it "redacts the key from an exception message passed as the message" do
    logger.error(IOError.new("request failed, headers: Authorization=#{secret}"))
    expect(io.string).to include("[redacted]")
    expect(io.string).to include("IOError")
    expect(io.string).not_to include(secret)
  end

  it "passes a clean exception through as the original object" do
    seen = nil
    spy = Logger.new(io)
    spy.formatter = proc { |_s, _t, _p, msg| seen = msg; "" }
    err = IOError.new("harmless")
    described_class.new(spy, secret).error(err)
    expect(seen).to equal(err)
  end

  it "redacts the block form, add/log and progname" do
    logger.warn { "block #{secret}" }
    logger.add(Logger::WARN, "add #{secret}", "prog-#{secret}")
    logger.log(Logger::WARN) { "log #{secret}" }
    inner.progname = "name-#{secret}"
    expect(logger.progname).to eq("name-[redacted]")
    expect(io.string).not_to include(secret)
    expect(io.string.scan("[redacted]").length).to be >= 4
  end

  it "redacts the key from a structured (non-string) message" do
    logger.info({ headers: { "Authorization" => secret } })
    expect(io.string).not_to include(secret)
    expect(io.string).to include("[redacted]")
  end

  it "does not evaluate the block when the level is disabled" do
    inner.level = Logger::ERROR
    called = false
    logger.debug { called = true; "x" }
    expect(called).to be false
  end

  it "leaves a key shorter than 20 characters alone" do
    short = described_class.new(inner, "k")
    short.warn("skipped a malformed flag")
    expect(io.string).to include("skipped a malformed flag")
    expect(io.string).not_to include("[redacted]")
  end

  it "delegates other logger methods" do
    logger.level = Logger::ERROR
    expect(inner.level).to eq(Logger::ERROR)
    expect(logger.respond_to?(:level)).to be true
  end

  it "does not double-wrap" do
    expect(described_class.wrap(logger, secret)).to equal(logger)
    expect(described_class.wrap(nil, secret)).to be_nil
  end
end
