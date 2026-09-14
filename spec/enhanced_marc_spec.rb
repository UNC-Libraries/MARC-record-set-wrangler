require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe 'enhanced_marc integration' do
  it 'decodes records with the classification methods Wrangler uses' do
    script = <<~'RUBY'
      require 'bundler/setup'
      require 'marc_wrangler'
      require 'enhanced_marc'

      record = MARC::Record.new
      record.leader[6] = 'a'
      record.leader[7] = 'm'
      record << MARC::ControlField.new('001', 'example-id')

      decoded = MARC::Reader.decode(MARC::Writer.encode(record))
      abort "unexpected record type: #{decoded.record_type.inspect}" unless decoded.record_type == 'BKS'
      unless decoded.bibliographic_level == 'Monograph/Item'
        abort "unexpected bibliographic level: #{decoded.bibliographic_level.inspect}"
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      '-Ilib',
      '-e',
      script,
      chdir: File.expand_path('..', __dir__)
    )

    expect(status).to be_success, stderr
  end
end
