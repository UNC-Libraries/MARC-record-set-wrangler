require 'spec_helper'
require 'tmpdir'

RSpec.describe MARC::Reader do
  it 'caches record offsets for indexed access' do
    records = %w[first second].map do |id|
      MARC::Record.new.tap do |record|
        record << MARC::ControlField.new('001', id)
      end
    end

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'records.mrc')
      writer = MARC::Writer.new(path)
      records.each { |record| writer.write(record) }
      writer.close

      File.open(path, 'rb') do |file|
        reader = described_class.new(file)
        reader.each_with_offset_caching.to_a

        expect(reader.offsets.length).to eq(3)
        expect(reader[0]['001'].value).to eq('first')
        expect(reader[1]['001'].value).to eq('second')
      end
    end
  end
end
