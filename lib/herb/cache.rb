# frozen_string_literal: true
# typed: false

require "digest"
require "fileutils"
require "json"
require "tempfile"

module Herb
  class Cache
    attr_reader :directory

    def initialize(directory = nil)
      @directory = directory || default_directory
      @mem = {}      # in-memory cache: key → compiled source string
      @mem_iseq = {} # in-memory cache: key → ISeq
    end

    def enabled?
      return true if ENV["HERB_CACHE"] == "1"

      Herb.configuration.cache_enabled?
    end

    def fetch(key)
      return nil unless enabled?

      # Check in-memory cache first
      mem_hit = @mem[key]
      return mem_hit if mem_hit

      path = cache_path(key)
      return nil unless File.exist?(path)

      src = File.read(path)
      @mem[key] = src
      src
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def store(key, compiled_src)
      return unless enabled?

      # Populate in-memory cache immediately
      @mem[key] = compiled_src

      dir = @directory
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      path = cache_path(key)

      # Atomic write via tempfile + rename to avoid partial reads
      tmp = Tempfile.new(["herb_cache_", ".rb"], dir)
      begin
        tmp.write(compiled_src)
        tmp.close
        File.rename(tmp.path, path)
      rescue StandardError
        tmp.close!
      end

      # Also store pre-compiled ISeq binary (skips Ruby parse on load)
      store_iseq(key, compiled_src)
    end

    # Fetch a pre-compiled ISeq binary. Returns an InstructionSequence
    # that can be evaluated directly, skipping both Herb compilation and
    # Ruby parsing. Returns nil on miss or if ISeq is unavailable.
    def fetch_iseq(key)
      return nil unless enabled?

      # Check in-memory ISeq cache first
      mem_hit = @mem_iseq[key]
      return mem_hit if mem_hit

      path = iseq_path(key)
      return nil unless File.exist?(path)

      data = File.binread(path)
      # Validate header: first line is "herb-iseq:RUBY_VERSION\n"
      header_end = data.index("\n")
      return nil unless header_end

      header = data[0...header_end]
      expected = "herb-iseq:#{RUBY_VERSION}"
      return nil unless header == expected

      binary = data[(header_end + 1)..]
      iseq = RubyVM::InstructionSequence.load_from_binary(binary)
      @mem_iseq[key] = iseq
      iseq
    rescue Errno::ENOENT, Errno::EACCES, TypeError, RuntimeError
      nil
    end

    def key_for(input, properties = {})
      fingerprint = {
        v: Herb::VERSION,
        escape: properties.fetch(:escape) { properties.fetch(:escape_html, false) },
        bufvar: properties[:bufvar] || properties[:outvar] || "_buf",
        freeze: properties[:freeze] || false,
        freeze_template_literals: properties.fetch(:freeze_template_literals, true),
        chain_appends: properties[:chain_appends] || false,
        strict: properties.fetch(:strict, true),
        validation_mode: properties.fetch(:validation_mode, :raise).to_s,
        debug: properties.fetch(:debug, false),
        ensure: properties[:ensure] || false,
      }

      escape = fingerprint[:escape]
      if escape
        fingerprint[:escapefunc] = properties.fetch(:escapefunc, "__herb.h")
        fingerprint[:attrfunc] = properties.fetch(:attrfunc, "__herb.attr")
        fingerprint[:jsfunc] = properties.fetch(:jsfunc, "__herb.js")
        fingerprint[:cssfunc] = properties.fetch(:cssfunc, "__herb.css")
      end

      data = input + "\0" + JSON.generate(fingerprint.sort.to_h)
      Digest::SHA256.hexdigest(data)
    end

    def clear!
      @mem.clear
      @mem_iseq.clear
      FileUtils.rm_rf(@directory)
    end

    def size
      return 0 unless Dir.exist?(@directory)

      Dir.glob(File.join(@directory, "*.rb")).length
    end

    private

    def cache_path(key)
      File.join(@directory, "#{key}.rb")
    end

    def iseq_path(key)
      File.join(@directory, "#{key}.iseq")
    end

    def store_iseq(key, compiled_src)
      iseq = RubyVM::InstructionSequence.compile(compiled_src)
      binary = iseq.to_binary

      path = iseq_path(key)
      header = "herb-iseq:#{RUBY_VERSION}\n"

      tmp = Tempfile.new(["herb_iseq_", ".iseq"], @directory)
      begin
        tmp.binmode
        tmp.write(header)
        tmp.write(binary)
        tmp.close
        File.rename(tmp.path, path)
      rescue StandardError
        tmp.close!
      end
    rescue StandardError, SyntaxError
      # ISeq compilation may fail for some generated code; source cache still works
    end

    def default_directory
      if ENV["HERB_CACHE_DIR"]
        ENV["HERB_CACHE_DIR"]
      else
        Herb.configuration.cache_directory
      end
    end
  end
end
