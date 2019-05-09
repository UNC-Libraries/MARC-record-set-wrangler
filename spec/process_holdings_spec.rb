# coding: utf-8
require 'spec_helper'
include MarcWrangler::ProcessHoldings

RSpec.describe MarcWrangler::ProcessHoldings do
  include SpecUtil

  describe 'process_holdings' do
    it 'adds 856$3 from 996 fulltext coverage data' do
      rec = make_rec
      rec << MARC::DataField.new('996', ' ', ' ', ['d', 'fulltext@1969-01~1970-04'], ['e', 'fulltext@volume:1;issue:1~volume:2;issue:1'])
      rec << MARC::DataField.new('856', '4', '0', ['u', 'https://ex.it'])
      rec = process_holdings(rec)[:rec]
      expect(rec['856']['3']).to eq('Full text coverage: Jan 1969 - Apr 1970')
    end

    it 'adds fallover 856$3 from 996 fulltext coverage data errors' do
      rec = make_rec
      rec << MARC::DataField.new('996', ' ', ' ', ['d', 'fulltext fulltext@ fulltext'], ['e', 'fulltext fulltext@ fulltext'])
      rec << MARC::DataField.new('856', '4', '0', ['u', 'https://ex.it'])
      rec = process_holdings(rec)[:rec]
      expect(rec['856']['3']).to eq('Full text coverage: Not all issues have been digitized. View resource for full text availability details.')
    end

    it 'does not add 856$3 from 996 ebook coverage data' do
      rec = make_rec
      rec << MARC::DataField.new('996', ' ', ' ', ['d', 'ebook'], ['e', 'ebook'])
      rec << MARC::DataField.new('856', '4', '0', ['u', 'https://ex.it'])
      rec = process_holdings(rec)[:rec]
      expect(rec['856']['3']).to be_nil
    end
  end

  describe 'format_summary' do
    it 'formats dates' do
      val = ['1969-01~1970-04']
      res = 'Jan 1969 - Apr 1970'
      expect(format_summary(val, :date)).to eq(res)
    end
  end
  
  describe 'get_996' do
    it "retrieves one fulltext 996" do
      rec = make_rec
      rec << MARC::DataField.new('996', ' ', ' ', ['d', 'fulltext'])
      expect(get_996(rec)['d']).to eq('fulltext')
    end
    it "does not retreive non-fulltext 996s" do
      rec = make_rec
      rec << MARC::DataField.new('996', ' ', ' ', ['d', 'ebook'])
      expect(get_996(rec)).to be_nil
    end
  end

  describe 'get_shortest_field' do
    it 'selects shortest 996' do
      f1 = MARC::DataField.new('996', ' ', ' ', ['d', 'fulltext@1969-01~1970-04'], ['e', 'fulltext@volume:1;issue:1~volume:2;issue:1'])
      f2 = MARC::DataField.new('996', ' ', ' ', ['d', 'fulltext@1969-01~1970-04'])
      expect(get_shortest_field([f1, f2])).to eq(f2)
    end
  end

  describe 'derive_summary' do
    it 'uses date if present' do
      date = 'fulltext@1923~1927 fulltext@1928~1929 fulltext@1944~1945'
      enum = 'fulltext@volume:117;issue:203~volume:117;issue:203'
      res = '1923 - 1927; 1928 - 1929; 1944 - 1945'
      expect(derive_summary(date, enum)).to eq(res)
    end
    it 'uses enum if date unusable' do
      date = 'fulltext fulltext@ fulltext'
      enum = 'fulltext@volume:117;issue:203~volume:117;issue:203'
      res = 'v.117:no.203'
      expect(derive_summary(date, enum)).to eq(res)
    end
    it 'returns error summary if all data unusable' do
      date = 'fulltext fulltext@ fulltext'
      enum = 'fulltext'
      res = 'ERROR - no usable coverage data'
      expect(derive_summary(date, enum)).to eq(res)
    end
  end

  describe 'split_holdings' do
    it 'splits multiple holdings statements in one field into an array of statements' do
      val = 'fulltext@1923-05-02~1923-06-30 fulltext@1926-12-01~1926-12-31 fulltext@1944-10-01~1944-10-31'
      arr = ['1923-05-02~1923-06-30', '1926-12-01~1926-12-31', '1944-10-01~1944-10-31']
      expect(split_holdings(val)).to eq(arr)
    end

    it 'ignores empty holdings statements' do
      val = 'fulltext fulltext@1950-01-01~1950-01-01'
      arr = ['1950-01-01~1950-01-01']
      expect(split_holdings(val)).to eq(arr)
    end
  end

  describe 'replace_long_summary' do
    it 'passes through summaries shorter than given length' do
      expect(replace_long_summary('abc', 5)).to eq(['abc', ''])
    end

    it 'replaces summaries longer than given length with standard value and generates info for logs' do
      summary = 'abcdefg'
      result = ['Not all issues have been digitized. View resource for full text availability details.',
                'INFO: long coverage data replaced with standard coverage statement']
      expect(replace_long_summary(summary, 5)).to eq(result)
    end
  end

  describe 'process_ranges' do
    it 'splits holdings statement into array (beginning, end)' do
      arr = ['1923-05-02~1923-06-30', '1926-12-01~1926-12-31', '1944-10-01~1944-10-31']
      res = [['1923-05-02', '1923-06-30'],
             ['1926-12-01', '1926-12-31'],
             ['1944-10-01', '1944-10-31']]
      expect(process_ranges(arr)).to eq(res)
    end

    it 'converts ranges with same start and end to single value' do
      arr = ['1923-05-02~1923-06-30', '1926-12-01~1926-12-31', '1944-10-01~1944-10-01']
      res = [['1923-05-02', '1923-06-30'],
             ['1926-12-01', '1926-12-31'],
             ['1944-10-01']]
      expect(process_ranges(arr)).to eq(res)
    end
  end

  describe 'format_date' do
    it 'handles year' do
      expect(format_date('1942')).to eq('1942')
    end
    it 'handles year-month' do
      expect(format_date('1942-02')).to eq('Feb 1942')
    end
    it 'handles year-month-day' do
      expect(format_date('1942-02-09')).to eq('Feb 9, 1942')
    end
  end
end
