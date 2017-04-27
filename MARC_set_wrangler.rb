# encoding: UTF-8

$LOAD_PATH << '.'
require 'csv'
require 'yaml'
require 'marc'
require 'marc_record'
require 'highline/import'
require 'pp'
require 'fileutils'

puts "\n\n"

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Get your config set up
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

# Get a hash of your config
config = begin
           YAML.load(File.open('config.yaml'))
         rescue ArgumentError => e
           puts "Could not parse YAML config file: #{e.message}"
         end
iconfig = config['institution']

# Find out what workflow and collection we're dealing with and set those configs
def return_specific_config(configsection, configlevel)
  choices = []
  configsection.each_key { |k| choices << k.to_sym }
  choose do |menu|
    menu.index = :number
    menu.index_suffix = ') '
    menu.prompt = "Which of the above #{configlevel}s do I use? "
    menu.choices(*choices) do |chosen|
      return configsection[chosen.to_s]
    end
  end
end
wconfig = return_specific_config(config['workflows'], 'workflow')
cconfig = return_specific_config(config['collections'], 'collection')

# create specific config hash for this process
def merge_configs(c1, c2)
  c1.merge!(c2) { |k, v1, v2|
    if k == 'id affix value'
      "#{v1}#{v2}"
    elsif v1.class.name == 'Boolean'
      v2
    elsif v1.class.name == 'Array'
      v1 + v2
    elsif v1.class.name == 'String'
      v2
    else
      v1.merge!(v2)
    end
  }
  c1.each_pair { |k, v|
    v.uniq! if v.class.name == 'Array'
  }
  return c1
end

thisconfig = iconfig.dup
thisconfig = merge_configs(thisconfig, wconfig)
thisconfig = merge_configs(thisconfig, cconfig)
pp(thisconfig) if thisconfig['show combined config']

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Set up basic in/out, variables, and data structures
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

# Set our list of MARC ID fields to clean or add affix to
idfields = []
idfields << thisconfig['main id'] if thisconfig['main id']
idfields << thisconfig['merge id'] if thisconfig['merge id']

# RecordInfo holds basic data about MARC records needed for matching ids and
#  other processing, as well as efficiently retrieving the full MARC record
#  from its file for processing
#  :id = String 001 value
#  :mergeids = Array of 019$a values
#  :sourcefile = String the path to the .mrc file the record is in
#  :warnings = Array warning messages associated with record
#  :overlay_type = Array of elements which may be either 'main id' or 'merge id'
class RecordInfo
  attr_accessor :id
  attr_accessor :mergeids
  attr_accessor :sourcefile
  attr_accessor :lookupfile
  attr_accessor :outfile
  attr_accessor :warnings
  attr_accessor :ovdata
  attr_accessor :overlay_type
  attr_accessor :under_ac
  attr_accessor :diff_status
  attr_accessor :ac_changed

  def initialize(id)
    @id = id
    @warnings = []
    @ovdata = []
    @overlay_type = []
  end  
end

# :will_overlay = ExistingRecordInfo object
class IncomingRecordInfo < RecordInfo
  alias :will_overlay :ovdata
  alias :will_overlay= :ovdata=
end

# :will_be_overlaid_by = IncomingRecordInfo object
class ExistingRecordInfo < RecordInfo
  alias :will_be_overlaid_by :ovdata
  alias :will_be_overlaid_by= :ovdata=
end

class Affix
  attr_reader :affix
  attr_reader :type

  def initialize(affix, type)
    @affix = affix
    if type =~ /(pre|suf)fix/
      @type = type
    else
      raise ArgumentError, "'affix type' option in config.yaml must be either 'prefix' or 'suffix'"
    end
  end

  def add_to_value(value)
    case @type
    when 'prefix'
      @affix + value
    when 'suffix'
      value + @affix
    end
  end

  def add_to_record(rec, id_elements)
    id_elements.each do |ide|
      e = SpecifiedMarcElement.new(ide)
      if rec.tags.include?(e.tag)
        rec.find_all { |field| field.tag == e.tag }.each do |field|
          case field.class.name
          when 'MARC::ControlField'
            field.value = add_to_value(field.value)
          when 'MARC::DataField'
            clean_sfs = field.subfields.select { |sf| e.subfields.include?(sf.code) }
            clean_sfs.each { |sf| sf.value = add_to_value(sf.value) }
          end
        end
      end
    end
    rec
  end
end

class IdCleaner
  attr_reader :cleaning_routine

  def initialize(cleaning_routine)
    @cleaning_routine = cleaning_routine
  end

  def clean(idvalue)
    @cleaning_routine.each do |step|
      idvalue.gsub!(/#{step['find']}/, step['replace'])
    end
    idvalue
  end

  def clean_record(rec, id_elements)
    id_elements.each do |ide|
      e = SpecifiedMarcElement.new(ide)
      if rec.tags.include?(e.tag)
        rec.find_all { |field| field.tag == e.tag }.each do |field|
          case field.class.name
          when 'MARC::ControlField'
            field.value = clean(field.value)
          when 'MARC::DataField'
            clean_sfs = field.subfields.select { |sf| e.subfields.include?(sf.code) }
            clean_sfs.each { |sf| sf.value = clean(sf.value) }
          end
        end
      end
    end
    rec
  end
end

class AuthorityControlStatus
  attr_reader :elvl_to_ac_map
  def initialize(spec)
    @elvl_to_ac_map = spec
  end
  
  def get_by_elvl(elvl)
    @elvl_to_ac_map[elvl]
  end
end

# Set up in/out directories
in_dir = 'incoming_marc'
ex_dir = 'existing_marc'
out_dir = 'output'
wrk_dir = 'working'

# Set up MARC writers
filestem = Dir.glob("#{in_dir}/*.mrc")[0].gsub!(/^.*\//, '').gsub!(/\.mrc/, '')
writers = {}
if thisconfig['incoming record output files']
  writeconfig = thisconfig['incoming record output files'].dup.delete_if { |k, v| v == 'do not output' }
else
  writers['default'] = MARC::Writer.new("#{out_dir}/#{filestem}_output.mrc")
  out_mrc = writers['default']
end

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Run checks on config logic
# --=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
if thisconfig['overlay merged records']
  if thisconfig['clean ids']
    unless thisconfig['merge id']
      log << ['Configuration warning', 'n/a', "Check your configs. Looks like you want to overlay merged records, but haven't specified a 'merge id' to clean to ensure proper overlay."]
      puts "\n\nWARNING:\nCheck your configs. Looks like you want to overlay merged records, but haven't specified a 'merge id' to clean to ensure proper overlay."
    end
  end
  unless thisconfig['use existing record set']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'overlay merged records' = true, 'use existing record set' must be true.\n\n")
  end
end

if thisconfig['report record status counts on screen']
  unless thisconfig['set record status by file diff']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'report record status counts on screen' = true, 'set record status by file diff' must be true. I can't report record status counts if I haven't figured out record statuses.\n\n")
  end
end

if thisconfig['manipulate 019 for overlay']
  unless thisconfig['overlay merged records']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'manipulate 019 for overlay' = true, 'overlay merged records' must be true.\n\n")
  end
end

if thisconfig['flag overlay type']
  unless thisconfig['overlay merged records']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'flag overlay type' = true, 'overlay merged records' must be true.\n\n")
  end
  unless thisconfig['overlay type flag spec']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'flag overlay type' = true, 'overlay type flag spec' must be configured.\n\n")
  end
end

if thisconfig['add AC MARC fields']
  unless thisconfig['add AC MARC spec']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'add AC MARC fields' = true, 'add AC MARC spec' must be configured. In other words --- I need to know what field(s) to add to records under AC.\n\n")
  end
end

if thisconfig['add noAC MARC fields']
  unless thisconfig['add noAC MARC spec']
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'add noAC MARC fields' = true, 'add noAC MARC spec' must be configured. In other words --- I need to know what field(s) to add to records NOTunder AC.\n\n")
  end
end

if thisconfig['elvl sets AC status']
  if thisconfig['elvl AC map']
    ac_status = AuthorityControlStatus.new(thisconfig['elvl AC map'])
  else
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'elvl sets AC status' = true, 'elvl AC map' must be configured.\n\n")
  end
end

if thisconfig['flag AC recs with changed headings']
  if thisconfig['fields under AC']
    ac_fields = thisconfig['fields under AC']
  else
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'flag AC recs with changed headings' = true, 'fields under AC' must be configured. I need to know what fields to compare in order to flag the records.\n\n")
  end

  if thisconfig['changed heading MARC spec']
    ac_changes_spec = thisconfig['changed heading MARC spec']
  else
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'flag AC recs with changed headings' = true, 'changed heading MARC spec' must be configured. I need to know what field(s) to add if the headings have changed.\n\n")
  end
end

# Set affix if it's going to be used, otherwise it is blank string
if thisconfig['use id affix']
  if idfields.size > 0
    unless thisconfig['affix type']
      abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'use id affix' = true, you need to specify 'affix type'\n\n")
    end
    unless thisconfig['id affix value']
      abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'use id affix' = true, you need to specify 'id affix value'\n\n")
    end
    puts "\n\nThe #{thisconfig['affix type']} #{thisconfig['id affix value']} will be added to #{idfields.join(', ')}."
    affix_handler = Affix.new(thisconfig['id affix value'], thisconfig['affix type'])
  else
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'use id affix' = true, you need to specify at least one of the following: 'main id', 'merge id'\n\n")
  end
end
# NOTE: Since we are comparing original files below, we don't need to add id suffixes
#  until we output the processed records.

if thisconfig['clean ids'] && idfields.size > 0
  cleaner = IdCleaner.new(thisconfig['clean ids'])
else
  abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'clean ids' = true, you need to specify at least one of the following: 'main id', 'merge id'\n\n")
end

if thisconfig['set record status by file diff']
  omission_spec = thisconfig['omit from comparison fields']
  omission_spec_sf = thisconfig['omit from comparison subfields']
end

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Define repeated procedures
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

# Produces array of RecInfo structs from the MARC files in a directory
def get_rec_info(dir, label)
  puts "\n\nGathering record info from #{dir} files:"
  recinfos = []
  rec_increment = 1
  infiles = Dir.glob("#{dir}/*.mrc")
  if infiles.size > 0
    infiles.each { |file|
      sourcefile = "#{dir}/#{file}"
      puts "  - #{sourcefile}"
      MARC::Reader.new(file).each { |rec|
        recid = begin
                  id = rec['001'].value.dup
                rescue NoMethodError => e
                  abort("\n\nSCRIPT FAILURE!\n#{label.capitalize} record(s) are missing 001 values, so I can't do any reliable comparisons with them.\n\n")
                end
        case label
        when 'existing'
          ri = ExistingRecordInfo.new(id)
          mypath = "working/#{rec_increment}.mrc"
          writer = MARC::Writer.new(mypath)
          writer.write(rec)
          writer.close
          ri.lookupfile = mypath
          rec_increment += 1
        when 'incoming'
          ri = IncomingRecordInfo.new(id)
        else
          abort("\n\nUnknown record set type (neither incoming nor existing).\n\n")
        end
        ri.mergeids = rec.get_019_vals
        ri.sourcefile = sourcefile
        recinfos << ri
      }
    }
    puts "There are #{recinfos.size} #{label} records."
    return recinfos
  else
    abort("\n\nSCRIPT FAILURE!:\nNo #{label} .mrc files found in #{dir}.\n\n")
  end
end

def make_rec_info_hash(ri_array)
  thehash = {}
  ri_array.each { |ri|
    if thehash.has_key?(ri.id)
      thehash[ri.id] << ri
    else
      thehash[ri.id] = [ri]
    end
  }

  # Check for dupe records in set.
  # If any are found, script stops
  # Otherwise, all hash values are now just one RecordInfo object
  ids_duplicated = []
  thehash.each_pair { |id, ri_array|
    if ri_array.size > 1
      ids_duplicated << id
    else
      thehash[id] = ri_array[0]
    end
  }

  if ids_duplicated.size > 0
    if thehash[ids_duplicated[0]][0].class.name == 'ExistingRecordInfo'
      name = 'EXISTING'
    else
      name = 'INCOMING'
    end
    abort("\n\nSCRIPT FAILURE!\nDUPLICATE RECORDS IN #{name} RECORD FILE(S):\nMultiple records in your #{name.downcase} record file(s) have the same 001 value(s).\nAffected 001 values: #{ids_duplicated.join(', ')}\nPlease duplicate your #{name.downcase} file(s) and try the script again.\n\n")
  else
    return thehash
  end  
end

def clean_id(rec, idfields, spec)
  idfields.each { |fspec|
    ftag = fspec[0,3]
    sfd = fspec[3] if fspec.size > 3
    recfields = rec.find_all { |fld| fld.tag == ftag }
    if recfields.size > 0
      recfields.each { |fld|
        fclass = fld.class.name
        if fclass == 'MARC::ControlField'
          id = fld.value
          spec.each { |fr|
            id.gsub!(/#{fr['find']}/, fr['replace'])
          }
        elsif fclass == 'MARC::DataField'
          fld.subfields.each { |sf|
            if sf.code == sfd
              id = sf.value
              spec.each { |fr|
                id.gsub!(/#{fr['find']}/, fr['replace'])
              }
            end
          }
        else
        end
      }
    end
  }
  return rec
end

def get_fields_by_spec(rec, spec)
  fields = []
  spec.each { |fspec|
    tmpfields = rec.find_all { |flds| flds.tag =~ /#{fspec['tag']}/ }
    if fspec.has_key?('i1')
      tmpfields.select! { |f| f.indicator1 =~ /#{fspec['i1']}/ }
    end
    if fspec.has_key?('i2')
      tmpfields.select! { |f| f.indicator2 =~ /#{fspec['i2']}/ }
    end
    if fspec.has_key?('field has')
      tmpfields.select! { |f| f.to_s =~ /#{fspec['field has']}/i }
    end
    if fspec.has_key?('field does not have')
      tmpfields.reject! { |f| f.to_s =~ /#{fspec['field does not have']}/i }
    end
    tmpfields.each { |f| fields << f }
  }
  #  puts fields
  return fields
end

def get_fields_for_comparison(rec, omitfspec, omitsfspec)
  to_omit = get_fields_by_spec(rec, omitfspec)
  to_compare = rec.reject { |f| to_omit.include?(f) }
  tags_w_sf_omissions = omitsfspec.keys
  compare = []
  to_compare.each { |cf|
    if cf.class.name == 'MARC::ControlField'
      compare << cf
    else
      if tags_w_sf_omissions.include?(cf.tag)
        sfs_to_omit = omitsfspec[cf.tag].chars
        newfield = MARC::DataField.new(cf.tag, cf.indicator1, cf.indicator2)
        cf.subfields.each { |sf|
          unless sfs_to_omit.include?(sf.code)
            newsf = MARC::Subfield.new(sf.code, sf.value)
            newfield.append(newsf)
          end
        }
        compare << newfield
      else
        compare << cf
      end
    end
  }
  compare_strings = []
  compare.each { |f|
    fs = f.to_s
    # fsdc = UnicodeUtils.compatibility_decomposition(fs)
    # compare_strings << fsdc
    compare_strings << fs 
  }
  compare_strings.sort!
  return compare_strings.uniq
end

class MarcEdit
  def initialize(rec)
    @rec = rec
  end

  def add_field(fspec)
    fs = fspec.dup
    field = MARC::DataField.new(fs['tag'], fs['i1'], fs['i2'])
    fs['subfields'].each do |sf|
      field.append(MARC::Subfield.new(sf['delimiter'], sf['value']))
    end
    @rec.append(field)
  end

  def add_field_with_parameter(fspec, replaces)
    fspec.each { |fs|
      sfval = ''
      f = MARC::DataField.new(fs['tag'], fs['i1'], fs['i2'])
      fs['subfields'].each { |sfs|
        sfval = sfs['value'].dup
        if replaces.size > 0
          replaces.each { |findrep|
            findrep.each_pair { |fnd, rep|
              sfval.gsub!(fnd, rep)
            }
          }
        end
        sf = MARC::Subfield.new(sfs['delimiter'], sfval)
        f.append(sf)
      }
      @rec.append(f)
    } 
  end

  def sort_fields
    old_ldr = @rec.leader
    field_hash = @rec.group_by { |field| field.tag }
    newrec = MARC::Record.new()
    field_hash.keys.sort!.each do |tag|
      field_hash[tag].each { |f| newrec.append(f) }
    end
    newrec.leader = old_ldr
    @rec = newrec
    @rec
  end
end

def check_for_multiple_overlays(sets)
  errs = []
  sets.each { |set|
    info_set_class = set[0].class.name
    case info_set_class
    when 'ExistingRecordInfo'
      type = 'existing'
      action = 'will be overlaid by incoming'
    else
      type = 'incoming'
      action = 'will overlay existing'
    end
    err_set = set.select { |ri| ri.ovdata.size > 1 }
    err_set.each { |ri|
      msg = "#{type.capitalize} #{ri.id} #{action} "
      ovs = []
      ri.ovdata.each { |ov|
        ovs << "#{ov.id} on #{ov.overlay_type}"
      }
      msg = msg + ovs.join(' ; ')
      errs << msg
    }
  }

  if errs.size > 0
    puts "\n\nSCRIPT FAILURE!\nPROBLEMS WITH MULTIPLE OVERLAY:"
    errs.each { |e| puts e }
    puts "Please either resolve these issues, or set 'ignore multiple overlays: true' in your config.yaml, and re-run the script\n\n"
    abort
  end
end

class MergeIdManipulator
  attr_reader :rec
  attr_reader :recinfo
  attr_reader :ex_rec_id
  
  def initialize(rec, recinfo)
    @rec = rec
    @recinfo = recinfo
    ex_ind = @recinfo.overlay_type.index('merge id')
    @ex_rec_id = @recinfo.ovdata[ex_ind].id
  end

  def fix
    matching_val = @rec.get_019_vals.select { |v| v == @ex_rec_id }
    matching_val = matching_val[0]
    nonmatching_val = @rec.get_019_vals.select { |v| v != @ex_rec_id }
    @rec.delete_fields_by_tag('019')
    newfield = (MARC::DataField.new('019', ' ', ' ', ['a', matching_val]))
    if nonmatching_val.size > 0
      nonmatching_val.each { |e| newfield.append(MARC::Subfield.new('a', e)) }
    end
    @rec.append(newfield)
    @rec
  end
end

class SpecifiedMarcElement
  attr_reader :tag
  attr_reader :subfields #array of relevant subfield delimiters

  def initialize(spec)
    copy = spec.dup
    @tag = copy.slice!(/^.../)
    @subfields = copy.chars
  end
end


# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Do the actual things...
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=


# Pull in our incoming and, if relevant, previously loaded MARC records
rec_info_sets = []
in_rec_info = get_rec_info(in_dir, 'incoming')
rec_info_sets << in_rec_info

if thisconfig['use existing record set']
  ex_rec_info = get_rec_info(ex_dir, 'existing')
  rec_info_sets << ex_rec_info
end

if thisconfig['clean ids']
  # clean the script's internally used ids before working with them
  puts "\n\nCleaning IDs in record info..."
  rec_info_sets.each { |set|
    set.each { |rec_info|
      rec_info.id = cleaner.clean(rec_info.id)
      if rec_info.mergeids.size > 0
        rec_info.mergeids.each { |mid|
          mid = cleaner.clean(mid)
        }
      end
    }
  }
end

# get record info hashes, indexed by 001 value, to work with
if thisconfig['use existing record set']
  ex_info = make_rec_info_hash(ex_rec_info)
end
in_info = make_rec_info_hash(in_rec_info)

def set_ovdata(in_match_id, in_ri, ex_info, ovtype)
  if ex_info.has_key?(in_match_id)
    ex_ri = ex_info[in_match_id]
    in_ri.ovdata << ex_ri
    in_ri.overlay_type << ovtype
    ex_ri.ovdata << in_ri
    ex_ri.overlay_type << ovtype
  end
end

if thisconfig['use existing record set']
  # identify main id overlays
  puts "\n\nChecking for overlays on main ID..."
  in_info.each_pair { |id, in_ri|
    set_ovdata(id, in_ri, ex_info, 'main id')
  }
  ov_main = in_rec_info.find_all { |ri| ri.overlay_type.include?('main id') }
  print " found #{ov_main.size}"

  if thisconfig['overlay merged records']
    # identify merge id overlays
    puts "\n\nChecking for overlays on merge ID..."
    in_info.each_pair { |id, in_ri|
      if in_ri.mergeids.size > 0
        in_ri.mergeids.each { |mid|
          set_ovdata(mid, in_ri, ex_info, 'merge id')
        }
      end
    }
    ov_merge = in_rec_info.find_all { |ri| ri.overlay_type.include?('merge id') }
    print " found #{ov_merge.size}"
  end
end

case thisconfig['ignore multiple overlays']
when true
  puts "\n\nWARNING. Will NOT check for multiple overlays. Analysis of whether record has changed will use first matching record only.\n"
when false
  check_for_multiple_overlays(rec_info_sets)
end

# process each incoming record
Dir.glob("#{in_dir}/*.mrc").each do |in_file|
  MARC::Reader.new(in_file).each do |rec|
    id_val = cleaner.clean(rec['001'].value.dup)
    ri = in_info[id_val]

    if thisconfig['use existing record set']
      if ri.ovdata.size > 0
        ex_ri = ri.ovdata[0]
        reader = MARC::Reader.new(ex_ri.lookupfile) 
        exrec = reader.first
      end
    end
    
    if thisconfig['set record status by file diff']
      if ri.ovdata.size > 0
        compnew = get_fields_for_comparison(rec, omission_spec, omission_spec_sf)
        compold = get_fields_for_comparison(exrec, omission_spec, omission_spec_sf)
        changed_fields = ( compnew - compold ) + ( compold - compnew )

        if changed_fields.size > 0
          ri.diff_status = 'CHANGE'
        else
          ri.diff_status = 'STATIC'
        end
      else
        ri.diff_status = 'NEW'
      end
    end
    
    next if ri.diff_status == 'STATIC' && thisconfig['incoming record output files']['STATIC'] == 'do not output'
    
    if thisconfig['flag AC recs with changed headings']
      if ri.ovdata.size > 0
        ac_new = get_fields_by_spec(rec, ac_fields).map { |f| f.to_s }
        ac_old = get_fields_by_spec(exrec, ac_fields).map { |f| f.to_s }
        changed_headings = (ac_new - ac_old) + (ac_old - ac_new)
        if changed_headings.size > 0
          ri.ac_changed = true
        end
      end
    end
    
    if thisconfig['warn about non-e-resource records']
      ri.warnings << 'Not an e-resource record?' unless rec.is_e_rec? == 'yes'
    end

    if thisconfig['warn about cat lang']
      catlangs = thisconfig['cat lang']
      reclang = rec.cat_lang
      ri.warnings << 'Not our language of cataloging' unless catlangs.include?(reclang)
    end

    if thisconfig['elvl sets AC status']
      elvl = rec.encoding_level
      case ac_status.get_by_elvl(elvl)
      when nil
        ri.warnings << "#{elvl} is not in elvl AC map. Please add to config."
      when 'AC'
        ri.under_ac = true
      when 'noAC'
        ri.under_ac = false
      end
    end

    if thisconfig['overlay merged records']
      rec = MergeIdManipulator.new(rec, ri).fix if ri.overlay_type.include?('merge id')
    end
    
    if thisconfig['clean ids']
      rec = cleaner.clean_record(rec, idfields)
    end

    if thisconfig['use id affix']
      rec = affix_handler.add_to_record(rec, idfields)
    end

    if thisconfig['flag rec status']
      reced = MarcEdit.new(rec)
      this_spec = thisconfig['rec status flag spec']
      this_replace = [{'[RECORDSTATUS]'=>ri.diff_status}]
      reced.add_field_with_parameter(this_spec, this_replace)
    end
    
    if thisconfig['flag overlay type']
      if ri.overlay_type.size > 0
        ri.overlay_type.each do |type|
          reced.add_field_with_parameter(thisconfig['overlay type flag spec'], [{'[OVTYPE]'=>type}])
        end
      end
    end

    if ri.ac_changed
      ac_changes_spec.each { |field_spec| reced.add_field(field_spec) }
    end
    
    case ri.under_ac
    when true
      if thisconfig['add AC MARC fields']
        reced = MarcEdit.new(rec)
        thisconfig['add AC MARC spec'].each { |field_spec| reced.add_field(field_spec) }
      end
    when false
      if thisconfig['add noAC MARC fields']
        thisconfig['add noAC MARC spec'].each { |field_spec| reced.add_field(field_spec) }
      end
    end

    if thisconfig['add MARC field spec']
      thisconfig['add MARC field spec'].each { |field_spec| reced.add_field(field_spec) }
    end

    if thisconfig['write warnings to recs']
      if ri.warnings.size > 0
        ri.warnings.each { |w|
          reced.add_field_with_parameter(thisconfig['warning flag spec'], [{'[WARNINGTEXT]'=>w}])
        }
      end
    end

    rec = reced.sort_fields

    if thisconfig['incoming record output files']
      status = ri.diff_status
      if writers.has_key?(writeconfig[status])
        writers[writeconfig[status]].write(rec)
        ri.outfile = writers[writeconfig[status]].fh.path
      elsif writeconfig.has_key?(status)
        writers[writeconfig[status]] = MARC::Writer.new("#{out_dir}/#{filestem}#{writeconfig[status]}.mrc")
        writers[writeconfig[status]].write(rec)
        ri.outfile = writers[writeconfig[status]].fh.path
      else
        ri.outfile = "not output"
        next
      end
    else
      out_mrc.write(rec)
      ri.outfile = out_mrc.fh.path
    end
    
    if thisconfig['log warnings']
      ri.warnings.map! { |w| [ri.sourcefile, ri.outfile, ri.id, w] }
    end
    
    #puts "\n#{rec}"
    #pp(ri)
  end
end

if thisconfig['report record status counts on screen']
    puts "\n\n-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    puts "RESULTS"

    in_rec_info.group_by { |ri| ri.diff_status }.each_pair do |k, v|
      puts "#{v.size} #{k} record(s)"
    end
end

if thisconfig['produce delete file']
  deletes = ex_rec_info.find_all { |ri| ri.will_be_overlaid_by.size == 0 }

  if deletes.size > 0
    dwriter = MARC::Writer.new("#{out_dir}/#{filestem}_deletes.mrc")

    deletes.group_by { |ri| ri.sourcefile }.each do |sourcefile, ri_set|
      ri_set.each do |ri|
        reader = MARC::Reader.new(ri.lookupfile)
        del_rec = reader.first

        if thisconfig['clean ids']
          del_rec = cleaner.clean_record(del_rec, idfields)
        end

        if thisconfig['use id affix']
          del_rec = affix_handler.add_to_record(del_rec, idfields)
        end

        dwriter.write(del_rec)
      end
    end
    dwriter.close
  end

  

  if thisconfig['report delete count on screen']
    puts "#{deletes.size} deletes"
  end
end

if thisconfig['log warnings']
  all_warnings = in_rec_info.map { |ri| ri.warnings if ri.warnings.size > 0 }.compact.flatten(1)
  if all_warnings.size > 0
    logpath = "#{out_dir}/#{filestem}_log.csv"
    log = CSV.open(logpath, "wb")
    log << ['source file', 'output file', 'rec id', 'warning']
    all_warnings.each { |w| log << w }
    log.close
  end
end


if thisconfig['incoming record output files']
  writer_list = writers.keys
  writer_list.each { |w| writers[w].close }
else
  out_mrc.close
end 

puts "\n\n -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\nAll important work is done! It's safe to use the files in the output directory now.\n -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=\n"
puts "It's going to take me a while to finish cleaning up my working files, though..."
ObjectSpace.each_object(IO) {|x| x.close }

#FileUtils.remove_dir('working', force = true)
FileUtils.rm Dir.glob('working/*.mrc'), :force => true
#puts "\nDone!\n\n"
