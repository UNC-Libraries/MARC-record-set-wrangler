# encoding: UTF-8

$LOAD_PATH << '.'
require 'csv'
require 'yaml'
require 'marc'
require 'marc_record'
require 'highline/import'
require 'pp'
require 'pstore'
require "unicode_utils/compatibility_decomposition"
require "unicode_utils/nfkc"
require "unicode_utils/nfd"
require "unicode_utils/nfkd"
require "unicode_utils/each_grapheme"

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
#  :index = Integer position of record in its sourcefile
#  :warnings = Array warning messages associated with record
#  :overlay_type = Array of elements which may be either 'main id' or 'merge id'
class RecordInfo
  attr_accessor :id
  attr_accessor :mergeids
  attr_accessor :sourcefile
  attr_accessor :index
  attr_accessor :warnings
  attr_accessor :ovdata
  attr_accessor :overlay_type

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

# Set up in/out directories
in_dir = 'incoming_marc'
ex_dir = 'existing_marc'
out_dir = 'output'

# Set up Pstore document for temp record storage/access
rec_access = PStore.new('rec_access.pstore')

# Set up MARC writers
Dir.chdir(in_dir)
filestem = Dir.glob('*.mrc')[0].gsub!(/\.mrc/, '')
Dir.chdir('..')
writers = {}
if thisconfig['incoming record output files']
  writeconfig = thisconfig['incoming record output files'].delete_if { |k, v| v == 'do not output' }
else
  writers['default'] = MARC::Writer.new("#{out_dir}/#{filestem}_output.mrc")
  out_mrc = writers['default']
end

# Set up logging, if specified
if thisconfig['log warnings']
  log = CSV.open("#{out_dir}/#{filestem}_log.csv", "wb")
  log << ['filename', 'rec id', 'warning']
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
  else
    abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'use id affix' = true, you need to specify at least one of the following: 'main id', 'merge id'\n\n")
  end
end
# NOTE: Since we are comparing original files below, we don't need to add id suffixes
#  until we output the processed records.

if thisconfig['clean ids'] && idfields.size == 0
  abort("\n\nSCRIPT FAILURE!\nPROBLEM IN CONFIG FILE: If 'clean ids' = true, you need to specify at least one of the following: 'main id', 'merge id'\n\n")
end

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Define repeated procedures
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

# Produces array of RecInfo structs from the MARC files in a directory
def get_rec_info(dir, label)
  puts "\n\nGetting record metadata from the following #{dir} files:"
  recinfos = []
  Dir.chdir(dir)
  infiles = Dir.glob('*.mrc')
  if infiles.size > 0
    puts infiles
    infiles.each { |file|
      index = 0
      sourcefile = "#{dir}/#{file}"
      MARC::Reader.new(file).each { |rec|
        recid = begin
                  id = rec['001'].value.dup
                rescue NoMethodError => e
                  abort("\n\nSCRIPT FAILURE!\n#{label.capitalize} record(s) are missing 001 values, so I can't do any reliable comparisons with them.\n\n")
                end
        case label
        when 'existing'
          ri = ExistingRecordInfo.new(id)
        when 'incoming'
          ri = IncomingRecordInfo.new(id)
        else
          abort("\n\nUnknown record set type (neither incoming nor existing).\n\n")
        end
        ri.mergeids = rec.get_019_vals
        ri.sourcefile = sourcefile
        ri.index = index
        recinfos << ri
        index += 1
      }
    }
    puts "There are #{recinfos.size} #{label} records."
    Dir.chdir('..')
    return recinfos
  else
    abort("\n\nSCRIPT FAILURE!:\nNo #{label} .mrc files found in #{dir}.\n\n")
  end
end

# Takes:
#  idvalue - the String value of an ID control field or data field subfield to be cleaned
#  spec - the 'clean id' specification, which is a list of find/replace operations
# Does:
#  specified find/replaces on the input String
# Returns:
#  modified idvalue String
def clean_id_value(idvalue, spec)
  spec.each { |fr|
    idvalue.gsub!(/#{fr['find']}/, fr['replace'])
  }
  return idvalue
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
    fs = f.to_s.encode(Encoding::UTF_8)
    # fsdc = UnicodeUtils.compatibility_decomposition(fs)
    # compare_strings << fsdc
    compare_strings << fs 
  }
  compare_strings.sort!
  return compare_strings.uniq
end

def put_matching_019_sf_first(rec)
  my019s = rec.get_019_vals
  match019 = ''
  rec.overlay_point.each { |op|
    match019 = op['019a'] if op.has_key?('019a')
  }
  nomatch019 = []
  my019s.each { |id| nomatch019 << id unless id == match019 }
  rec.delete_fields_by_tag('019')
  newfield = (MARC::DataField.new('019', ' ', ' ', ['a', match019]))
  if nomatch019.size > 0
    nomatch019.each { |e| newfield.append(MARC::Subfield.new('a', e)) }
  end
  rec.append(newfield)
end

def add_marc_var_fields(rec, fspec)
  fspec.each { |fs|
    sfval = ''
    f = MARC::DataField.new(fs['tag'], fs['i1'], fs['i2'])
    fs['subfields'].each { |sfs|
      sf = MARC::Subfield.new(sfs['delimiter'], sfs['value'])
      f.append(sf)
    }
    rec.append(f)
  }
end

def add_marc_var_fields_replacing_values(rec, fspec, replaces)
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
    rec.append(f)
  }
end

def setup_rec_access(dir, rec_access)
  Dir.chdir(dir)
  infiles = Dir.glob('*.mrc')
  if infiles.size > 0
    infiles.each { |file|
      path = "#{dir}/#{file}"
      index = 0
      rawhash = {}
      MARC::Reader.new(file).each_raw { |rec|
        rawhash[index] = rec
        index += 1
      }
      rec_access.transaction {
        rec_access[path] = rawhash
      }
    }
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
  setup_rec_access(ex_dir, rec_access)
end

if thisconfig['clean ids']
  # clean the script's internally used ids before working with them
  rec_info_sets.each { |set|
    set.each { |rec_info|
      rec_info.id = clean_id_value(rec_info.id, thisconfig['clean ids'])
      if rec_info.mergeids.size > 0
        rec_info.mergeids.each { |mid|
          mid = clean_id_value(mid, thisconfig['clean ids'])
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
  puts "\nChecking for overlays on main ID..."
  in_info.each_pair { |id, in_ri|
    set_ovdata(id, in_ri, ex_info, 'main id')
  }

  if thisconfig['overlay merged records']
    # identify merge id overlays
    puts "\nChecking for overlays on merge ID..."
    in_info.each_pair { |id, in_ri|
      if in_ri.mergeids.size > 0
        in_ri.mergeids.each { |mid|
          set_ovdata(mid, in_ri, ex_info, 'merge id')
        }
      end
    }
  end
end

check_for_multiple_overlays(rec_info_sets) unless thisconfig['ignore multiple overlays']

if thisconfig['set record status by file diff']
  
  overlays = in_rec_info.find_all { |ri| ri.will_overlay.size > 0 }
  ov_main = overlays.find_all { |ri| ri.overlay_type.include?('main id') }
  ov_merge = overlays.find_all { |ri| ri.overlay_type.include?('merge id') }
  news = in_rec_info.find_all { |ri| ri.will_overlay.size == 0 }

  if thisconfig['report record status counts on screen']
    puts "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    puts "RESULTS"
    puts "#{overlays.size} overlays (#{ov_main.size} on main id, #{ov_merge.size} on merge id)" 
    puts "#{news.size} news"
  end
end

if thisconfig['produce delete file']
  deletes = ex_rec_info.find_all { |ri| ri.will_be_overlaid_by.size == 0 }
  if thisconfig['report delete count on screen']
    puts "#{deletes.size} deletes"
  end
end


# rec_info_sets.each { |set|
#   set.each { |ri| pp(ri); puts ''}
# }


#     if thisconfig['overlay merged records']
#       if thisconfig['manipulate 019 for overlay']
#         rec.overlay_point.each { |op| put_matching_019_sf_first(rec) if op.has_key?('019a') }
#       end
#     end

#     if thisconfig['flag overlay type']
#       if rec.overlay_point.size > 0
#         ovtypes = []
#         rec.overlay_point.each { |op| ovtypes << op.keys }
#         ovtypes.flatten!
#         ovtypes_x = []
#         ovtypes.each { |type| ovtypes_x << "OVERLAY on #{type}"}
#         ovtype = ovtypes_x.flatten.join(', ')
#       else
#         ovtype = 'NEW'
#       end
#       add_marc_var_fields_replacing_values(rec, thisconfig['overlay type flag spec'], [{'[OVTYPE]'=>ovtype}])
#     end

#     if thisconfig['set record status by file diff']
#       if rec.overlay_point.size > 0
#         omission_spec = thisconfig['omit from comparison fields']
#         omission_spec_sf = thisconfig['omit from comparison subfields']
#         compnew = get_fields_for_comparison(rec, omission_spec, omission_spec_sf)
#         old_rec_id = rec.overlay_point[0].values[0]
#         compold = get_fields_for_comparison(ex_ids[old_rec_id], omission_spec, omission_spec_sf)
#         rec.changed_fields = compnew - compold
#         if rec.changed_fields.size > 0
#           rec.diff_status = 'CHANGE'
#         else
#           rec.diff_status = 'STATIC'
#         end
#       else
#         rec.diff_status = 'NEW'
#       end
#     end

#     if thisconfig['flag rec status']
#       add_marc_var_fields_replacing_values(rec, thisconfig['rec status flag spec'], [{'[RECORDSTATUS]'=>rec.diff_status}])
#     end
#   end

#   if thisconfig['flag AC recs with changed headings']
#     if rec.overlay_point.size > 0
#       ac_spec = thisconfig['fields under AC']
#       ac_spec_omit_sfs = thisconfig['omit from AC fields subfields']
#       ac_new = get_fields_by_spec(rec, ac_spec).map { |f| f.to_s }
#       old_rec_id = rec.overlay_point[0].values[0]
#       ac_old = get_fields_by_spec(ex_ids[old_rec_id], ac_spec).map { |f| f.to_s }
#       ac_new.sort!
#       ac_old.sort!
#       rec.changed_ac_fields = ac_new - ac_old
#       if rec.changed_ac_fields.size > 0
#         if thisconfig['changed heading MARC spec']
#           add_marc_var_fields(rec, thisconfig['changed heading MARC spec'])
#         else
#           raise StandardError, "You need to define 'changed heading MARC spec' in config" 
#         end
#       end
#     end
#   end

#   if thisconfig['warn about non-e-resource records']
#     if rec.is_e_rec? == 'no'
#       rec.warnings << 'Not an e-resource record?'
#     end
#   end

#   if thisconfig['warn about cat lang']
#     catlangs = thisconfig['cat lang']
#     reclang = rec.cat_lang
#     unless catlangs.include?(reclang)
#       rec.warnings << 'Not our language of cataloging'
#     end
#   end

#   if thisconfig['elvl sets AC status']
#     elvl = rec.encoding_level
#     ac_map = thisconfig['elvl AC map']
#     if ac_map
#       rec.ac_action = ac_map[elvl]
#     else
#       raise ArgumentError, "Please configure 'elvl AC map' in config.yaml"
#     end

#     if rec.ac_action == 'AC'
#       if thisconfig['add AC MARC fields']
#         if thisconfig['add AC MARC spec']
#           add_marc_var_fields(rec, thisconfig['add AC MARC spec'])
#         else
#           raise ArgumentError, "Please configure 'add AC MARC spec' in config.yaml"
#         end
#       end
#     end

#     if rec.ac_action == 'noAC'
#       if thisconfig['add noAC MARC fields']
#         if thisconfig['add noAC MARC spec']
#           add_marc_var_fields(rec, thisconfig['add noAC MARC spec'])
#         else
#           raise ArgumentError, "Please configure 'add noAC MARC spec' in config.yaml"
#         end
#       end
#     end
#   end

#   if thisconfig['add MARC field spec']
#     add_marc_var_fields(rec, thisconfig['add MARC field spec'])
#   end

#   if thisconfig['write warnings to recs']
#     if rec.warnings.size > 0
#       rec.warnings.each { |w|
#         add_marc_var_fields_replacing_values(rec, thisconfig['warning flag spec'], [{'[WARNINGTEXT]'=>w}])
#         if thisconfig['log warnings']
#           log << [rec.source_file, rec[idtag].value, w]
#         end
#       }
#     end
#   end

#   def add_affix(value, affix, type)
#     if type == 'suffix'
#       value = value + affix
#     elsif type == 'prefix'
#       value = affix + value
#     else
#       raise ArgumentError, "'affix type' option in config.yaml must be either 'prefix' or 'suffix'"
#     end
#     return value
#   end

#   if thisconfig['use id affix']
#     myfix = thisconfig['id affix value']
#     unless myfix == ''
#       idfields.each { |fspec|
#         ftag = fspec[0,3]
#         sfd = fspec[3] if fspec.size > 3
#         rec.find_all { |fld| fld.tag == ftag }.each { |fld|

#           fclass = fld.class.name
#           if fclass == 'MARC::ControlField'
#             fld.value = add_affix(fld.value, myfix, thisconfig['affix type'])
#           elsif fclass == 'MARC::DataField'
#             fld.subfields.each { |sf|
#               if sf.code == sfd
#                 sf.value = add_affix(sf.value, myfix, thisconfig['affix type'])
#               end
#             } 
#           end
#         }
#       }
#     end
#   end

#   if thisconfig['incoming record output files']
#     status = rec.diff_status
#     if writers.has_key?(status)
#       writers[status].write(rec)
#     elsif writeconfig.has_key?(status)
#       writers[status] = MARC::Writer.new("#{out_dir}/#{filestem}#{writeconfig[status]}.mrc")
#       writers[status].write(rec)
#     else
#       next
#     end
#   else
#     out_mrc.write(rec)
#   end
# }

# if thisconfig['report record status counts on screen']
#   puts "\n\n-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
#   puts "Record status counts"
#   puts "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
#   mynew = in_mrc.select { |r| r.diff_status == 'NEW' }
#   mychange = in_mrc.select { |r| r.diff_status == 'CHANGE' }
#   mystatic = in_mrc.select { |r| r.diff_status == 'STATIC' }
#   puts "#{mynew.size} new -- #{mychange.size} change -- #{mystatic.size} static"
# end

# if thisconfig['produce delete file']
#   deletes = ex_ids.keep_if { |recid, rec| rec.overlay_point.size == 0 }
#   if deletes.size > 0
#     dwriter = MARC::Writer.new("#{out_dir}/#{filestem}_deletes.mrc")
#     deletes.each_value { |rec|
#       if thisconfig['use id affix']
#         myfix = thisconfig['id affix value']
#         unless myfix == ''
#           if thisconfig['affix type'] == 'suffix'
#             rec[idtag].value += myfix
#           elsif thisconfig['affix type'] == 'prefix'
#             rec[idtag].value = myfix + rec[idtag].value
#           else
#             raise ArgumentError, "'affix type' option in config.yaml must be either 'prefix' or 'suffix'" 
#           end
#         end
#       end
#       dwriter.write(rec)
#     }
#     dwriter.close
#   end
#   puts "#{deletes.size} delete" if thisconfig['report delete count on screen']
# end

# if thisconfig['log warnings']
#   log.close
#   logname = "#{out_dir}/#{filestem}_log.csv"
#   line_count = `wc -l "#{logname}"`.strip.split(' ')[0].to_i
#   File.delete(logname) if line_count == 1
# end

# if thisconfig['incoming record output files']
#   writer_list = writers.keys
#   writer_list.each { |w| writers[w].close }
# else
#   out_mrc.close
# end 

# puts "\nDone!\n\n"
