# encoding: UTF-8

require 'marc_wrangler'

module MarcWrangler
  module ProcessHoldings

    FALLOVER_SUMMARY = 'Not all issues have been digitized. View resource for full text availability details.'
    MAX_LENGTH = 250
    
    def process_holdings(rec)
      result = {}

      the996 = get_996(rec)

      if the996
        summary = derive_summary(the996['d'], the996['e'])
        length_chk = replace_long_summary(summary, MAX_LENGTH)
        summary = length_chk[0]
        result[:msg] = length_chk[1] unless length_chk[1] == ''
      else
        summary = ''
      end

      if summary == ''
        result[:rec] = rec
      elsif summary['ERROR']
        result[:rec] = write_summary_to_856(rec, FALLOVER_SUMMARY)
        result[:msg] = summary
      else
        result[:rec] = write_summary_to_856(rec, summary)
      end
      return result
    end

    def write_summary_to_856(rec, summary)
      rec['856'].append(MARC::Subfield.new('3', "Full text coverage: #{summary}"))
      rec
    end

    def replace_long_summary(summary, length)
      info = ''
      if summary.length > length
        summary =  FALLOVER_SUMMARY
        info = 'INFO: long coverage data replaced with standard coverage statement'
      end        
      return [summary, info]
    end

    def format_summary(data, category)
      data.each { |e| fix_enum(e) } if category == :enum

      ranges = process_ranges(data)
      to_join = []
      ranges.each do |r|
        r.map! { |e| format_date(e) } if category == :date
        if r.length == 1
          to_join << r.first
        else
          to_join << "#{r[0]} - #{r[1]}"
        end
      end

      return to_join.join('; ')
    end
    
    def derive_summary(dates, enum)
      if dates && split_holdings(dates)
        summary = format_summary(split_holdings(dates), :date)
      elsif enum && split_holdings(enum)
        summary = format_summary(split_holdings(enum), :enum)
      else
        summary = 'ERROR - no usable coverage data'
      end
      return summary
    end
    
    # returns the shortest fulltext 996 from record or returns nil
    def get_996(rec)
      all_996s = rec.fields.find_all { |f| f.tag == '996' && f.value.include?('fulltext') }
      case all_996s.length
      when 1
        return all_996s.first
      when 0
        return nil
      else
        return get_shortest_field(all_996s)
      end
    end

    # gets shortest field from an array of fields
    def get_shortest_field(fields)
      fields = fields.sort_by { |f| f.value.length }
      fields.first
    end

    # splits multiple holdings statements in one field into an array of statements
    # drops empty holdings statements
    def split_holdings(data)
      data.split(/ ?fulltext@?/).reject! { |e| e == '' }
    end

    def fix_enum(data)
      data.gsub!('volume:', 'v.')
      data.gsub!('issue:', 'no.')
      data.gsub!(';', ':')
    end

    def process_ranges(array)
      output = []
      array.each do |pair|
        pa = pair.split('~')
        output << pa.uniq
      end
      return output
    end

    def format_date(date)  
      pieces = date.split('-')
      case pieces.length
      when 1
        return pieces[0]
      when 2
        d = Date.new(pieces[0].to_i, pieces[1].to_i, 1)
        return d.strftime('%b %Y')
      when 3
        d = Date.new(pieces[0].to_i, pieces[1].to_i, pieces[2].to_i)
        return d.strftime('%b %-d, %Y')
      end
    end
  end
end
