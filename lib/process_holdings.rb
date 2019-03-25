# encoding: UTF-8

require 'date'
require 'marc'

module ProcessHoldings
  def process_holdings(rec)
    the996 = rec.fields.find { |f| f.tag == '996' && f.value.include?('fulltext') }

    if the996
      dates = rec['996']['d']
      enum = rec['996']['e']
      
      summary_parts = []
      if dates && split_holdings(dates)
        dates = split_holdings(dates)
        dates = process_pairs(dates)
        dates.each do |e|
          if e.length == 1
            summary_parts << format_date(e[0])
          else
            summary_parts << "#{format_date(e[0])} - #{format_date(e[1])}"
          end
        end
      elsif enum && split_holdings(enum)
        enum = split_holdings(enum) 
        enum.each { |e| fix_enum(e) }
        enum = process_pairs(enum)
        enum.each do |e|
          if e.length == 1
            summary_parts << e[0]
          else
            summary_parts << "#{e[0]} - #{e[1]}"
          end
        end
      else
        summary = 'ERROR - coverage data empty after processing'
      end

      summary = summary_parts.join('; ') if summary_parts.length > 0
      summary = 'ERROR - no coverage summary created' if summary == ''
      
      unless summary.match('ERROR')
        rec['856'].append(MARC::Subfield.new('3', "Full text coverage: #{summary}"))
      end
    else
      summary = ''
    end
    
    return [rec, summary]
  end

  def split_holdings(data)
    data.split(/ ?fulltext@?/).reject! { |e| e == '' }
  end

  def fix_enum(data)
    data.gsub!('volume:', 'v.')
    data.gsub!('issue:', 'no.')
    data.gsub!(';', ':')
  end

  def process_pairs(array)
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

  #   errs = []
  #   writer = MARC::Writer('output/with_holdings.mrc')
  
  # MARC::Reader.new('incoming_marc/20190315_ORIG_updates_ser.mrc').each do |rec|  
  # #MARC::Reader.new('test996.mrc').each do |rec|
  #   summary = process_holdings(rec)
  #   errs << summary if summary.match('ERROR')
  #   writer.write(rec)
  # end

  # writer.close

  # File.open "output/holdings_generation_errors.txt", "wb" do |f|
  #   errs.each {|l| f.puts l}
  # end
end
