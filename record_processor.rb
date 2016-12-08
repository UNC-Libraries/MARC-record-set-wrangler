$LOAD_PATH << '.'
require 'csv'
require 'marc'
require 'marc_record'
#require 'marc_extended'
require 'json'
require "highline/import"

config = JSON.parse(File.new("config.json").read)
# Incoming MARC records
mrcfile = "data/recs.mrc"

# List of 001 field values from existing records in your system/workflow
# These are the 001s from the records that should be overlaid by
#   some/all of the records in recs.mrc
exfile = "data/ids_in_cat.txt"

existing_001s_missing_suffix = []
$file_warnings = {}

cts = {
  'records' => 0,
  'match on 001' => 0,
  'match on 019' => 0,
  'no match' => 0,
}

# Reads in the existing record 001s and populates an array with them for lookup
$existing_001s = []
File.open(exfile, "r").readlines.each do |ln|
  line = ln.chomp
  if config['id_suffix'] != ''
    if line.end_with?(config['id_suffix'])
      $existing_001s << line
    else
      existing_001s_missing_suffix << line unless line == '001'
      $existing_001s << line + config['id_suffix']
    end
  else
    $existing_001s << line
  end
end


$goodwriter = MARC::Writer.new("output/edited_good.mrc")
$warnwriter = MARC::Writer.new("output/edited_warnings.mrc")

filetype = ''

def get_filetype_input
  puts "FILE TYPES"
  puts "a = additions / new"
  puts "c = changes / updates"
  puts "d = deletes"
  input = ask("What file type are you processing? Enter a, c, or d.")
  return input
end

until filetype =~ /^[acd]$/
  filetype = get_filetype_input()
end

def clean_id(rec, tag)
  id = rec[tag].value
  newid = id.gsub(/^(oc[mn]|on)/, '').gsub(/ *$/, '').gsub(/\\$/, '')
  rec[tag].value = newid
  return rec
end

def process_update_reasons(rec, decisions)
  the598s = rec.find_all {|f| f.tag == '598'}
  reasons = []
  the598s.each do |f|
    f.inspect
    sf = f['a']
    if sf =~ /^Reason for updated record: /
      sf.gsub!(/^Reason for updated record: */, '')
      unless sf == ' '
        sf.split(' - ').each { |r| reasons << r }
      end
    end
  end

  keepct = 0

  if reasons.size > 0
    reasons.each do |reason|
      rec.reasons_for_update << reason
      if reason =~ /^Master record variable field\(s\) change/
        clean_reason = 'Master record variable field(s) change'
        reason.gsub(/^Master record variable field\(s\) change: /, '').split(', ').each {|f| rec.changed_fields << f}
      elsif reason =~ /^Added to collection/
        clean_reason = 'Added to collection'
      elsif reason =~ /^Removed from collection/
        clean_reason = 'Removed from collection'
      else
        clean_reason = reason
      end
      
      if decisions[clean_reason] == 'keep'
        keepct += 1
      elsif decisions[clean_reason] == nil
        rec.warnings << "Record contains 598 field update reason that I don\'t know how to handle: \"#{reason}\". Please add this reason to config"
      end
    end
  end
  
  if keepct > 0
    rec.retain_based_on_update_reason = true
  else
    rec.retain_based_on_update_reason = false
  end
end

def set_AC_on_Elvl(rec, decisions)
  elvl = rec.encoding_level
  if decisions[elvl] == 'AC'
    rec.elvl_ac = true
  elsif decisions[elvl] == 'noAC'
    rec.elvl_ac = false
  else
    rec.elvl_ac = nil
    rec.warnings << "Record LDR encoding level (#{elvl}) has no associated authority control decision in config."
  end
  return rec.elvl_ac
end

def process_019_matching(rec, suffix)
  my019s = rec.get_019_vals
  if my019s.size > 0
    match019 = ''
    nomatch019 = []
    my019s.each do |oldid|
      chkid = oldid + suffix
      if $existing_001s.include?(chkid)
        match019 = chkid
        rec.overlay_point << '019'
      else
        nomatch019 << chkid
      end
    end

    unless match019 == ''
      rec.delete_fields_by_tag('019')
      newfield = (MARC::DataField.new('019', ' ', ' ', ['a', match019]))
      if nomatch019.size > 0
        nomatch019.each do |e|
          newfield.append(MARC::Subfield.new('a', e))
        end
      end
      rec.append(newfield)
    end
    
  end
  return rec
end

def set_existing_ac(rec, erec)
  if erec.under_authority_control?
    rec.existing_ac = true
  end
  return rec.existing_ac
end

def add_fields(rec, config)
  config.each do |f|
    newf = MARC::DataField.new(f['tag'], f['i1'], f['i2'])
    f['subfields'].each { |sf| newf.append(MARC::Subfield.new(sf['delimiter'], sf['value'])) }
    #    puts newf.inspect
    rec.append(newf)
  end
  return rec
end

def finish_record(rec, instruct, marcwarn)
  if rec.warnings.size > 0
    rec.warnings.each do |warning|
      if $file_warnings[warning]
        $file_warnings[warning] << rec._001
      else
        $file_warnings[warning] = [rec._001]
      end
    end
  end

  if instruct == 'skip'
  #puts "Skipped #{rec._001} due to update reason: #{rec.reasons_for_update.join(' - ')}"
  else
    if marcwarn == 'true'
      if rec.warnings.size > 0
        rec.warnings.each do |warning|
          rec.append(MARC::DataField.new('999', '9',  '9', ['a', warning]))
        end
      end
    end
    if instruct == 'warn'
      $warnwriter.write(rec)
    else
      $goodwriter.write(rec)
    end
  end
end

def convert_erec_to_mrc(erec)
  ldr = nil
  ctrl = []
  var = []

  erec.rec_data.each do |f|
    if f == ''
      next f
    elsif f =~ /^LDR/
      ldr = f.gsub(/^LDR\s+/, '')
      ldr.gsub!(/\s$/, '')
    elsif f =~ /^00/
      fa = []
      fa << /^.../.match(f).to_s
      fa << /^...\s+(.*)\s/.match(f)[1].to_s
      ctrl << fa
    else
      m = /^(...) (.)(.) (.*) $/.match(f)
      tag = m[1]
      i1 = m[2]
      i2 = m[3]
      recdata = m[4]
      unless recdata.start_with?("|")
        recdata = "|a" + recdata
      end
      sfsplit = recdata.split("|")
      sfsplit.shift
      sfs = []
      sfsplit.each do |sf|
        m = /^(.)(.*)$/.match(sf)
        sfs << [m[1], m[2]]
      end
      var << [tag, i1, i2, sfs]
    end
  end

  mrec = MARC::Record.new
  mrec.leader = ldr
  ctrl.each do |f|
    mrec.append(MARC::ControlField.new(f[0], value = f[1]))
  end
  var.each do |f|
    vf = MARC::DataField.new(f[0], f[1], f[2])
    f[3].each {|sf| vf.append(MARC::Subfield.new(sf[0], sf[1].gsub(/&#59;/,';'))) }
    mrec.append(vf)
  end

  erec.marc = mrec
  return mrec
end

def get_ac_fields(rec)
  acrules = {
    "100" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "110" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "111" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "130" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "240" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "600" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "610" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "611" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "630" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "650" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "651" => [{ "i1" => ".", "i2" => " 012", "sf2" => "na", "sfexclude" => 'uw4569' },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcac", "sfexclude" => 'uw4569' }],
    "700" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "710" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "711" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "730" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "800" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "810" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "811" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "830" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "840" => [{ "i1" => ".", "i2" => ".", "sf2" => "na", "sfexclude" => 'uw4569' }],
    "655" => [{ "i1" => ".", "i2" => "0", "sf2" => "na", "sfinclude" => "a" },
              { "i1" => ".", "i2" => "7", "sf2" => "lcsh|mesh|lcgft|gsafd", "sfinclude" => "a" }]
  }

  acfields = []
  
  acrules.each_pair do |tag, rules|
    tag_fields = rec.fields(tag)
    if tag_fields.size > 0
      #      puts "Working on #{tag} rules"
      tag_fields.each do |f|
        #        puts "   #{f.to_s}"
        fi1 = f.indicator1
        fi2 = f.indicator2
        sf2 = f.find_all {|sf| sf.code == '2'}
        output_field = ''

        rules.each do |r|
          #            puts "      RULE: #{r.inspect}"
          rkeep = 0
          i1m = nil
          i2m = nil
          
          i1m = true if r['i1'] == '.' || r['i1'].include?(fi1)
          i2m = true if r['i2'] == '.' || r['i2'].include?(fi2)
          if i1m && i2m
            if r['sf2'] == 'na'
              rkeep = 1
            else
              if sf2.size == 0
                rkeep = 0
              elsif sf2.size > 1
                rkeep = 0
              else
                sf2v = sf2[0].value
                rkeep = 1 if /(#{r['sf2']})/.match(sf2v)
              end
            end
          end

          if rkeep > 0
            keepf = "#{tag} #{fi1}#{fi2} "
            f.each do |sf|
              if r['sfinclude']
                keepf = keepf + "$#{sf.code} #{sf.value} " if r['sfinclude'].include?(sf.code)
              elsif r['sfexclude']
                keepf = keepf + "$#{sf.code} #{sf.value} " unless r['sfexclude'].include?(sf.code)
              end
            end
            acfields << keepf
          #              puts "         Keep"
          else
            #              puts "         Trash"
          end
        end
      end
    end
  end

  rec.ac_fields = acfields.sort
  return rec.ac_fields
end

MARC::Reader.new(mrcfile).each do |rec|
  cts['records'] += 1
  existing_rec = ''

  if config["clean_id"] == 'true'
    rec = clean_id(rec, config['IDtag'])
  end

  unless config['id_suffix'] == ''
    rec[config['IDtag']].value = rec[config['IDtag']].value + config['id_suffix']
  end

  the001 = rec._001
  print "\n#{the001}\n"
  if config['update_reason_processing'] == 'true' && filetype =~ /[cd]/
    process_update_reasons(rec, config['update_reasons'])
    if rec.retain_based_on_update_reason == false
      reasons = rec.reasons_for_update.join(' - ')
      rec.warnings << "Skipped based on update reason: #{reasons}"
      finish_record(rec, "skip", config['write_warnings_to_999s'])
      next
    end
  end

  if config["warn_non_e"] == 'true'
    if rec.is_e_rec? == 'no'
      rec.warnings << 'Not an e-resource record?'
      finish_record(rec, "warn", config['write_warnings_to_999s'])
      next
    end
  end

  if config['warn_non_eng_cat_lang'] == 'true'
    unless rec.cat_lang == 'eng'
      rec.warnings << 'Non-English language of cataloging'
      finish_record(rec, "warn", config['write_warnings_to_999s'])
      next
    end
  end

  rec.overlay_point << '001' if $existing_001s.include?(the001)

  process_019_matching(rec, config['id_suffix'])

  if config['set AC on Elvl'] == 'true'
    set_AC_on_Elvl(rec, config['Elvl AC decisions'])
  end

  if config['keep ebk 655s'] == 'false'
    rec.delete_ebk_655s()
  end

  if config['set AC on existing'] == 'true'
    # Do not try to find out if existing record is under AC if no existing record will be overlaid
    if rec.overlay_point.size > 0
      existing_rec = ClassicCatalog::OCLCLookup.new(the001)
      set_existing_ac(rec, existing_rec)
      # If record is already under AC in ILS, it stays under AC regardless of Elvl
      if rec.elvl_ac == false && rec.existing_ac == true
        rec.append(MARC::DataField.new('999', '8',  '8', ['a', "Under AC because it was already under AC"]))
        rec.elvl_ac = true
      end
      if rec.existing_ac == true
      end

      convert_erec_to_mrc(existing_rec)
      eaf = get_ac_fields(existing_rec.marc)
      print "\n-=-=-=-=-\nAC fields existing\n"
      puts eaf
      new_af = get_ac_fields(rec)
      if  eaf == new_af
#        rec.append(MARC::DataField.new('999', '7',  '7', ['a', "AC cat date: Global update CAT DATE to prevent this record being re-sent to LTI"]))
        rec.ac_action = "do not send to LTI. "
      else
#        rec.append(MARC::DataField.new('599', ' ',  ' ', ['a', "LTIEXP"]))
        rec.ac_action = "send to LTI"
        diff = eaf - new_af
#        puts diff
        # puts eaf
        # puts "-=-="
        # puts new_af
      end
    else
#      rec.ac_
    end
    puts rec.ac_action
  end

  if rec.elvl_ac || rec.existing_ac
    add_fields(rec, config['add AC fields'])
  else
    add_fields(rec, config['add noAC fields'])
  end

  finish_record(rec, "good", config['write_warnings_to_999s'])

  
end

puts "#{cts['records']} total records processed."
unless $file_warnings.empty?
  $file_warnings.each_pair do |k, v|
    puts "#{v.size} records with warning: #{k}"
  end

  if config["write_warnings_to_log"] == 'true'
    t = Time.now
    timestring = t.strftime("%Y-%m-%d_%H-%M")
    log = "output/log_#{timestring}.csv"

    CSV.open(log, "wb") do |csv|
      $file_warnings.each_pair do |k, v|
        v.each { |recid| csv << [recid, k] }
      end
    end

    puts "Details on warnings written to #{log}."
  end

  if config['write_warnings_to_999s'] == 'true'
    puts "Warnings written to a 999 99 field in the relevant output MARC record(s)."
  end
  
end
