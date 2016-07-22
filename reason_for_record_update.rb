# ruby 2.3
# runs on .mrc file
# usage:
# ruby wcm_reason_for_change_processing.rb

require "marc"
require "csv"
require "net/http"

#  -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
#    SCRIPT INPUT
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Incoming MARC records
mrcfile = "data/recs.mrc"

unless File.exist?(mrcfile)
  puts "\n\nERROR: #{mrcfile} is missing. Please check file names and run script again.\n\n"
  exit
end

# Prepares to create a log file if there are any warnings/errors
t = Time.now
timestring = t.strftime("%Y-%m-%d_%H-%M")
log = "output/log_#{timestring}.csv"
errs = [['001 value','Message']]


rules = {
  "Collection change" => "load",
  "KB URL change" => "load",
  "Master record encoding level change" => "load",
  "OCLC control number change" => "load",
  "Custom text" => "discard",
  "KB provider name change" => "discard",
  "655 only" => "compare 655s",
  "RDA" => "load",
}

lti_fields = [
  '100', '110', '111', '130',
  '600', '610', '611', '630',
  '700', '710', '711', '730',
  '800', '810', '811', '830',
]

marcwriter = MARC::Writer.new("output/edited.mrc")

def check655(rec, my001)
  #LTI controls genre/form headings following these patterns:
  # - 655 .0 with no $2
  # - 655 .7 with $2lcsh
  # - 655 .7 with $2lcgft
  findings = ''

  # get 655s from existing records in ILS, by calling the classic web OPAC
  ex655s = []
  # URL does e-book scoped OCLC number search
  marcurl = URI("http://webcat.lib.unc.edu/search~S33?/o#{my001}/o#{my001}/1%2C1%2C1%2CB/marc&FF=o#{my001}&1%2C1%2C/indexsort=-")
  response = Net::HTTP.get_response(marcurl)
  if response.message == 'OK'
    response.body.gsub!(/\n       /m, '')
    lines = response.body.split("\n")
    lines.each do |ln|
      if /^655 .. (?!Electronic)/ =~ ln
        if /^655 .0/ =~ ln
          g = /^655 .. (.*)$/.match(ln) unless ln.include?('$2')
          ex655s << g[1]
        elsif /^655 .7 .*(\$2| )(lcsh|lcgft|lcgtf|lgft)/ =~ ln
          g = /^655 .. (.*)$/.match(ln)
          ex655s << g[1]
        end
      end
    end
  else
    findings = 'LTI'
  end
  puts ex655s.inspect if ex655s.size > 0
end

reader = MARC::Reader.new(mrcfile)
for rec in reader
  reasons = []
  chfields = []
  my001 = rec['001'].value.gsub!(/\D/,'')
  
  # Check for language of cataloging. If not English (blank or eng), then:
  #  - report to log
  #  - do not output record -- skip to next record without further processing
  catlang = rec['040']['b']
  unless catlang == 'eng' || catlang == ''
    errs << [my001, 'Non-English language of cataloging']
    next
  end

  rec.fields("598").each do |f|
    sfa = f['a']
    if sfa.start_with?("Reason for updated record: ")
      sfa.gsub!(/Reason for updated record: /, '')
      sfa.split(' - ').each do |r|
        if r.start_with?("Added to collection", "Removed from collection")
          reasons << "Collection change"
        elsif r.include?("Master record 040 $e RDA change")
          reasons << "RDA"
        elsif r.start_with?("Master record variable field(s) change: ")
          r.gsub!(/Master record variable field\(s\) change: /, '')
          varfields = r.split(', ')
          if varfields.size == 1 && varfields[0] == '655'
            reasons << "655 only"
          else
            if varfields.any? { |vf| lti_fields.include?(vf) }
              reasons << "LTI varfields"
            else
              reasons << "other varfields"
            end
          end
        else
          reasons << r
        end
      end
    end
  end
  reasons.uniq!


  keeper_ct = 0
  reasons.each do |r|
    if r == "655 only"
        check655(rec, my001)
    elsif r == "other varfields"
      keeper_ct += 1
    elsif r == "LTI varfields"
      keeper_ct += 1
      rec << MARC::DataField.new('599', ' ', ' ', ['a', 'LTIEXP'])
    elsif rules[r] == "load"
      keeper_ct += 1
    else
      puts "I don't know what to do with reason: #{r}" unless rules[r] == "discard"
    end
  end
end  
#   elsif ct_019s == 1
#     # Look at each $a value in the 019.
#     # Add suffix if necessary
#     # Compare it to existing 001 list.
#     # If it matches, this needs to be the FIRST 019$a in the field to acheive overlay,
#     #  due to limitations with III load profiling.
#     the_019 = rec['019']
#     subfield_a = the_019.find_all { |sf| sf.code == 'a' }

#     subfield_a.each do |sf|
#       if usesuffix == 'y'
#         num = sf.value + suffix
#       else
#         num = sf.value
#       end
      
#       if existing_001s.include? num
#         match_019 = num
#         match_on_019 = true
#       else
#         no_match_019s << num
#       end
#     end

#     # If there was an 019 value match, rewrite that 019 field.
#     if match_on_019
#       ct_match_019 += 1
#       rec.fields.delete(rec['019'])
#       new019 = MARC::DataField.new('019', ' ', ' ', ['a', match_019])
#       if no_match_019s.count > 0
#         no_match_019s.each do |val|
#           new019.append(MARC::Subfield.new('a', val))
#         end
#       end
#       rec << new019
#     end

#     # Warn about records that matched on both 001 and 019 values
#     if match_on_001 && match_on_019
#       errs << ['MARC', the_001, 'Match on both 001 and 019. Edited record output only to 001-match file if split file option was used.']
#     end
#   end

#   ct_no_match += 1 unless match_on_001 || match_on_019

#   if splitfile == 'y'
#     if match_on_001
#       match001writer.write(rec)
#     elsif match_on_019
#       match019writer.write(rec)
#     else
#       nomatchwriter.write(rec)
#     end
#   else
#     marcwriter.write(rec)
#   end
#   end

# puts "#{ct_recs} : record in incoming MARC file\n"
# puts "#{ct_match_001} : records matching on 001\n"
# puts "#{ct_match_019} : records matching on 019\n"
# puts "#{ct_no_match} : records with no match\n\n"

# if ct_recs != (ct_match_001 + ct_match_019 + ct_no_match)
#   puts "WARNING: More output records than input records, indicating weird matching has occurred. See log file.\n\n"
# end

# if errs.count > 1
#   CSV.open(log, 'wb') do |csv|
#     errs.each { |r| csv << r }
#   end
# else
#   puts "No warnings or errors written to log.\n"
# end
