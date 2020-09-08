# frozen_string_literal: true

require 'pronto'
require 'open3'
require 'pathname'

module Pronto
  PyrightOffence = Struct.new(:file, :severity, :start_line, :end_line, :message) do
    def self.create_from_json(json)
      new(
        Pathname.new(json[:file]),
        json[:severity].to_sym,
        json.dig(:range, :start, :line),
        json.dig(:range, :end, :line),
        json[:message]
      )
    end
  end

  class Pyright < Runner
    def initialize(patches, commit = nil)
      super(patches, commit)
    end

    def run
      return [] unless python_patches

      file_args = python_patches
        .map(&:new_file_full_path)
        .join(' ')

      return [] if file_args.empty?

      # Running on entire project for now
      # Import detection does not work properly when running on files
      # https://github.com/microsoft/pyright/issues/1015
      stdout, stderr, = Open3.capture3("#{pyright_executable} --lib --outputjson")
      stderr.strip!

      puts "WARN: pronto-pyright:\n\n#{stderr}" unless stderr.empty?

      puts stdout

      json = JSON.parse(stdout, symbolize_names: true)
      messages = json[:diagnostics]
        .map { |issue| PyrightOffence.create_from_json(issue) }
        .compact
        .map { |o| [patch_line_for_offence(o), o] }
        .reject { |(line, _)| line.nil? }
        .map { |(line, offence)| create_message(line, offence) }

      messages
    end

    private

    def pyright_executable
      'npx pyright'
    end

    def python_patches
      @python_patches ||= @patches
        .select { |p| p.additions.positive? }
        .select { |p| p.new_file_full_path.extname == '.py' }
    end

    def patch_line_for_offence(offence)

      # Pyright line numbers are 0 based where pronto are 1 based.
      # Add 1 to pyright line numbers in order to compare
      python_patches
        .select { |patch| patch.new_file_full_path == offence.file }
        .flat_map(&:added_lines)
        .select { |patch_lines| ((offence.start_line+1)..(offence.end_line+1)) === patch_lines.new_lineno }
        .max(&:new_lineno)
    end

    def create_message(patch_line, offence)
      Message.new(
        offence.file.to_s,
        patch_line,
        offence.severity,
        offence.message,
        nil,
        self.class
      )
    end
  end
end
