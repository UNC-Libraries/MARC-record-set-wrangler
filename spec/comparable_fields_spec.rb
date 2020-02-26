require 'spec_helper'

RSpec.describe MarcWrangler::ComparableField do
  describe '#norm_string' do
    xit 'normalizes utf-8 strings' do
    end

    it 'also handles marc-8 encoded strings' do
      marc8 = "$c\xC32008"
      expect(described_class.norm_string(marc8)).to eq('$c©2008')
    end

    context 'string is not valid utf-8 or marc-8' do
      it 'returns original, unnormalized, string' do
        str = "\xC8"
        expect(described_class.norm_string(str)).to eq(str)
      end
    end
  end
end
