require 'spec_helper'
require 'tmpdir'

RSpec.describe 'binary MARC IO' do
  it 'preserves record fields and UTF-8 text through a round trip' do
    record = MARC::Record.new
    record.leader[9] = 'a'
    record << MARC::ControlField.new('001', 'example-id')
    record << MARC::DataField.new('245', '1', '0', ['a', 'Café'])

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'records.mrc')
      writer = MARC::Writer.new(path)
      writer.write(record)
      writer.close

      decoded = File.open(path, 'rb') do |file|
        MARC::Reader.new(file, external_encoding: 'UTF-8').first
      end

      expect(decoded['001'].value).to eq('example-id')
      expect(decoded['245']['a']).to eq('Café')
    end
  end
end
