# ruby 1.9
# runs on .mrc file
# usage:
# ruby overlay_on_019.rb

require "marc"
require "csv"
require "highline/import"

#  -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
#    SCRIPT INPUT
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Incoming MARC records
mrcfile = "data/recs.mrc"

# List of 001 field values from existing records in your system/workflow
# These are the 001s from the records that should be overlaid by
#   some/all of the records in recs.mrc
exfile = "data/001s.txt"

unless File.exist?(mrcfile)
  puts "\n\nERROR: #{mrcfile} is missing. Please check file names and run script again.\n\n"
  exit
end

unless File.exist?(exfile)
  puts "\n\nERROR: #{exfile} is missing. Please check file names and run script again.\n\n"
  exit
end

# Prepares to create a log file if there are any warnings/errors
t = Time.now
timestring = t.strftime("%Y-%m-%d_%H-%M")
log = "output/log_#{timestring}.csv"
errs = [['Source','001 value','Message']]

# If the answer to the following is yes, 3 output files will be produced.
#  - one with records that should overlay due to identical 001 values
#  - one with records that should overlay due to existing 001 / incoming 019 match
#  - one with records that should not overlay existing records
# Some of the files may be empty.

# If the answer to this is no, 1 output file will be produced containing all your records.
# The script will report how many records are in each of the 3 categories, even
#   if you don't physically split the output file by those categories
splitfile = ask("Do you want to split the .mrc file based on how the records match (on 001, 019, or not at all)? y/n")

if splitfile == 'y'
  match001writer = MARC::Writer.new("output/match_on_001.mrc")
  match019writer = MARC::Writer.new("output/match_on_019.mrc")
  nomatchwriter = MARC::Writer.new("output/no_match.mrc")
else
  marcwriter = MARC::Writer.new("output/edited.mrc")
end

# At UNC-CH, we append a alphabetic suffix to OCNs in e-resource records that come in batches.
#  This prevents accidental overlay of:
#   - print records (if e-batch for some reason is using a print record for an e-resource)
#   - e-records for other collections (we maintain one bib per title per collection)
# The following questions ask whether or not the collection being processed has an
#   associated OCN suffix, and, if so, what the suffix is.
# If you tell the script you are using a suffix, it does the following:
#  - checks the 001 values in you existing records (from 001s.txt) and warns about any that
#    are missing the suffix
#  --  for processing, adds the suffix to these
#  --  you need to add the suffix to the actual record in your system to get an overlay
#  - adds the suffix to the 001 and 019 values in the incoming MARC records
usesuffix = ask("Does this collection use a suffix on the OCN? y/n")
suffix = ask("What's the OCN suffix for this collection? (examples: spr, acs, etc...") if usesuffix == 'y'

# Reads in the existing record 001s and populates an array with them for lookup
existing_001s = []
File.open(exfile, "r").readlines.each do |ln|
  line = ln.chomp
  if usesuffix == 'y'
    if line.end_with?(suffix)
      existing_001s << line
    else
      errs << ['001 list',line,'001 in catalog missing suffix'] unless line == '001'
      existing_001s << line + suffix
    end
  else
    existing_001s << line
  end
end

# set up count variables so we can report on numbers for each category of match 
ct_recs = 0
ct_match_001 = 0
ct_match_019 = 0
ct_no_match = 0


MARC::Reader.new(mrcfile).each do |rec|
  # housekeeping
  ct_recs += 1
  match_on_001 = false

  # Carefully get the 001 or 001s.
  # Check that there is 1 and only 1 001 in the record
  # Write a warning otherwise
  the_001s = rec.fields("001")
  ct_001s = the_001s.count

  if ct_001s != 1
        errs << ['MARC', rec['001'].value, 'A record is either missing an 001 field, or has too many 001 fields.']
  else
    # If the number of 001s is ok, clean the value so it consists of numbers only
    # Append suffix if applicable
    the_001 = rec['001'].value
    the_001.sub!(/\D/,'')

    if usesuffix == 'y'
      the_001 += suffix
      rec.fields.delete(rec['001'])
      new001 = MARC::ControlField.new('001',the_001)
      rec << new001
    end

    # If this 001 value is in your list of existing 001s, set as an 001 match
    if existing_001s.include? the_001
      match_on_001 = true
      ct_match_001 += 1
    end
  end

  # Note that there is no "else" clause separating match_on_001 and match_on_019
  # This means a record can conceivably match on both
  match_on_019 = false

  # Much of this 019 processing is required due to the fact that III Millennium
  #  will only overlay based on the FIRST 019 $a in incoming records. If
  #  the matching value is in the 2nd or 47th 019$a, the record will be inserted
  #  as new, creating a duplicate

  # Carefully get 019 field(s) and warn if there is more than one.
  the_019s = rec.fields('019')
  ct_019s = the_019s.count
  # The following 2 variables are used to re-write the 019 to ensure overlay if it
  #  contains a value that matches an existing 001
  # Will be set to the 019 value that matches an existing 001 and become the first
  #   subfield
  match_019 = ''
  # Will contain all 019 values that don't match existing 001s and be written as
  #  subsequent subfields
  no_match_019s = [] 

  if ct_019s > 1
    errs << ['MARC', 'the_001', 'Record has more than one 019 field.']
  elsif ct_019s == 1
    # Look at each $a value in the 019.
    # Add suffix if necessary
    # Compare it to existing 001 list.
    # If it matches, this needs to be the FIRST 019$a in the field to acheive overlay,
    #  due to limitations with III load profiling.
    the_019 = rec['019']
    subfield_a = the_019.find_all { |sf| sf.code == 'a' }

    subfield_a.each do |sf|
      if usesuffix == 'y'
        num = sf.value + suffix
      else
        num = sf.value
      end
      
      if existing_001s.include? num
        match_019 = num
        match_on_019 = true
      else
        no_match_019s << num
      end
    end

    # If there was an 019 value match, rewrite that 019 field.
    if match_on_019
      ct_match_019 += 1
      rec.fields.delete(rec['019'])
      new019 = MARC::DataField.new('019', ' ', ' ', ['a', match_019])
      if no_match_019s.count > 0
        no_match_019s.each do |val|
          new019.append(MARC::Subfield.new('a', val))
        end
      end
      rec << new019
    end

    # Warn about records that matched on both 001 and 019 values
    if match_on_001 && match_on_019
      errs << ['MARC', the_001, 'Match on both 001 and 019. Edited record output only to 001-match file if split file option was used.']
    end
  end

  ct_no_match += 1 unless match_on_001 || match_on_019

  if splitfile == 'y'
    if match_on_001
      match001writer.write(rec)
    elsif match_on_019
      match019writer.write(rec)
    else
      nomatchwriter.write(rec)
    end
  else
    marcwriter.write(rec)
  end
  end

puts "#{ct_recs} : record in incoming MARC file\n"
puts "#{ct_match_001} : records matching on 001\n"
puts "#{ct_match_019} : records matching on 019\n"
puts "#{ct_no_match} : records with no match\n\n"

if ct_recs != (ct_match_001 + ct_match_019 + ct_no_match)
  puts "WARNING: More output records than input records, indicating weird matching has occurred. See log file.\n\n"
end

if errs.count > 1
  CSV.open(log, 'wb') do |csv|
    errs.each { |r| csv << r }
  end
else
  puts "No warnings or errors written to log.\n"
end
