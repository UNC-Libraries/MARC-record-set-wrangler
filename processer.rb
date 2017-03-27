$LOAD_PATH << '.'
require 'csv'
require 'yaml'
require 'marc'
require 'marc_record'
require 'highline/import'
require 'pp'

# Get a hash of your config
config = begin
           YAML.load(File.open('config.yaml'))
         rescue ArgumentError => e
           puts "Could not parse YAML config file: #{e.message}"
         end
iconfig = config['institution']

# Find out what workflow and collection we're dealing with and set those configs
def return_specific_config(configsection)
  choices = []
  configsection.each_key { |k| choices << k.to_sym }
  choose do |menu|
    menu.index = :number
    menu.index_suffix = ') '
    menu.prompt = 'Which workflow do I use? '
    menu.choices(*choices) do |chosen|
      return configsection[chosen.to_s]
    end
  end
end
wconfig = return_specific_config(config['workflows'])
cconfig = return_specific_config(config['collections'])

# create specific config hash for this process
def merge_configs(c1, c2)
  c1.merge!(c2) { |k, v1, v2|
    if k == 'id affix value'
      "#{v1}#{v2}"
    elsif v1.class.name == 'Boolean'
      v2
    elsif v1.class.name == 'Array'
      v1 + v2
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
pp(thisconfig)

# set the idtag for easy access in rest of script
idtag = thisconfig['record id']['tag']

# Set up in/out directories
in_dir = 'incoming_marc'
ex_dir = 'last_processed_marc_ORIG'
out_dir = 'output'

# Set up MARC writers
out_mrc = MARC::Writer.new("#{out_dir}/output.mrc")

# Set up logging, if specified
if thisconfig['log warnings']
  log = CSV.open("#{out_dir}/log.csv", "wb")
  log << ['filename', 'rec id', 'warning']
end

def get_recs(dir, label)
  recs = []
  Dir.chdir(dir)
  infiles = Dir.glob('*.mrc')
  if infiles.size > 0
    infiles.each { |file|
      MARC::Reader.new(file).each { |rec|
        rec.source_file = "#{dir}/#{file}"
        recs << rec
      }
    }
    puts "\n\nGrabbed #{recs.size} records from the following #{dir} files:"
    puts infiles
    Dir.chdir('..')
    return recs
  else
    raise IOError, "No #{label} .mrc files found in #{dir}." 
  end
end

def clean_id(rec, tag)
  id = rec[tag].value
  newid = id.gsub(/^(oc[mn]|on)/, '').gsub(/ *$/, '').gsub(/\\$/, '')
  rec[tag].value = newid
  return rec
end

def get_fields_by_spec(rec, spec)
  fields = []
  spec.each { |fspec|
    tmpfields = rec.find_all { |flds| flds.tag =~ /#{fspec['tag']}/ }
    if fspec.has_key?('i1')
      tmpfields.keep_if { |f| f.indicator1 =~ /#{fspec['i1']}/ }
    end
    if fspec.has_key?('i2')
      tmpfields.keep_if { |f| f.indicator2 =~ /#{fspec['i2']}/ }
    end
    if fspec.has_key?('field has')
      tmpfields.keep_if { |f| f.to_s =~ /#{fspec['field has']}/i }
    end
    if fspec.has_key?('field does not have')
      tmpfields.reject! { |f| f.to_s =~ /#{fspec['field does not have']}/i }
    end
    tmpfields.each { |f| fields << f }
  }
  return fields
end

def get_fields_for_comparison(rec, omitfspec, omitsfspec)
  to_omit = get_fields_by_spec(rec, omitfspec)
  to_compare = rec.reject { |f| to_omit.include?(f) }
  sfomit = omitsfspec
  compare = []
  to_compare.each { |f|
    if f.class.name == 'MARC::DataField'
      if omitsfspec.size > 0
        omitsfspec.each { |ef| #edit field
          tag_w_sf_omissions = ef.keys[0]
          if f.tag == tag_w_sf_omissions
            sfs_in_field = f.codes
            sfs_to_omit = ef.values[0].chars
            puts sfs_to_omit.inspect
            puts "will work on sf omissions for #{tag_w_sf_omissions}."
          end
        }
      else
        puts "not doing sf omissions"
        compare << f
      end
    else
      compare << f
    end

  }
  return compare.sort!
end

def get_019_matches(rec, the_idtag, ex_id_list)
  my019s = rec.get_019_vals
  if my019s.size > 0
    match019 = []
    my019s.each do |chkid|
      if ex_id_list.has_key?(chkid)
        match019 << chkid
        rec.overlay_point << {'019' => chkid}
        ex_id_list[chkid].overlay_point << {'019' => rec[the_idtag].value}

        # Interpreting 019-related .overlay_point values
        # {'019'=>'x'}
        # INCOMING RECORD
        # x = the recid value in the existing record that will get overlaid
        #     this incoming rec's 019$a value that matches the recid value in existing record
        # EXISTING RECORD
        # x = the recid value of the record that will overlay this record
      end
    end
  end
end

def put_matching_019_sf_first(rec)
  my019s = rec.get_019_vals
  match019 = ''
  rec.overlay_point.each { |op|
    match019 = op['019'] if op.has_key?('019')
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

def add_marc_var_fields_replacing_values(rec, fspec, replaces)
  fspec.each { |fs|
    sfval = ''
    f = MARC::DataField.new(fs['tag'], fs['i1'], fs['i2'])
    fs['subfields'].each { |sfs|
      sfval = sfs[1].dup
      if replaces.size > 0
        replaces.each { |findrep|
          findrep.each_pair { |fnd, rep|
            sfval.gsub!(fnd, rep)
          }
        }
      end
      sf = MARC::Subfield.new(sfs[0], sfval)
      f.append(sf)
    }
    rec.append(f)
  }
end

# Pull in our incoming and, if relevant, previously loaded MARC records
in_mrc = get_recs(in_dir, 'incoming')
ex_mrc = get_recs(ex_dir, 'existing') if thisconfig['use existing record set']

# Set affix if it's going to be used, otherwise it is blank string
if thisconfig['use id affix']
  puts "\n\nID #{thisconfig['affix type']} I will use is: #{thisconfig['id affix value']}"
end
# NOTE: Since we are comparing original files below, we don't need to add id suffixes
#  until we output the processed records.


if thisconfig['use existing record set']
  # Set up hash of existing records, keyed by idtag value, for comparing sets
  # rec.overlay_point of {'019'=>x} here means:
  #  - this record will be overlaid by incoming record with idtag value x
  #  - incoming record's idtag value x presumably does NOT match this record's
  #  -   idtag value
  #  - the overlay will be on an 019$a value in the incoming record
  ex_ids = {}

  ex_mrc.each { |rec|
    clean_id(rec, idtag) if thisconfig['clean ids']
    ex_ids[rec[idtag].value] = rec
  }
end

# Process incoming records
in_mrc.each { |rec|
  clean_id(rec, idtag) if thisconfig['clean ids']

  if thisconfig['use existing record set']
    # Set record.overlay_point of incoming record to idtag info if there's a match on main record id
    # Since this match relies on main record id being the same in incoming and existing
    #  records, also set record.overlay_point of existing record.  
    if ex_ids.has_key?(rec[idtag].value)
      op = {idtag => rec[idtag].value}
      rec.overlay_point << op
      exrec = ex_ids[rec[idtag].value]
      exrec.overlay_point << op
    end

    if thisconfig['overlay matchpoint includes 019']
      # Check for overlays between existing 001 and any 019$a in an incoming record
      get_019_matches(rec, idtag, ex_ids)
      if thisconfig['manipulate 019 for overlay']
        rec.overlay_point.each { |op| put_matching_019_sf_first(rec) if op.has_key?('019') }
      end
    end

    if thisconfig['flag overlay type']
      if rec.overlay_point.size > 0
        ovtypes = []
        rec.overlay_point.each { |op| ovtypes << op.keys }
        ovtypes.flatten!
        ovtypes_x = []
        ovtypes.each { |type| ovtypes_x << "OVERLAY on #{type}"}
        ovtype = ovtypes_x.flatten.join(', ')
      else
        ovtype = 'NEW'
      end
      add_marc_var_fields_replacing_values(rec, thisconfig['overlay type flag spec'], [{'[OVTYPE]'=>ovtype}])
    end
    
    if thisconfig['set record status by file diff']
      if rec.overlay_point.size > 0
        omission_spec = thisconfig['omit from comparison fields']
        omission_spec_sf = thisconfig['omit from comparison subfields']
        compnew = get_fields_for_comparison(rec, omission_spec, omission_spec_sf)
        old_rec_id = rec.overlay_point[0].values[0]
        compold = get_fields_for_comparison(ex_ids[old_rec_id], omission_spec, omission_spec_sf)
        rec.changed_fields = compnew - compold
        if rec.changed_fields.size > 0
          rec.diff_status = 'CHANGE'
        elsif rec.overlay_point.size == 0
          rec.diff_status = 'NEW'
        else
          rec.diff_status = 'STATIC'
        end
      end
    end

    if thisconfig['flag diff status']
      add_marc_var_fields_replacing_values(rec, thisconfig['diff status flag spec'], [{'[DIFFTYPE]'=>rec.diff_status}])
    end
  end
  
  if thisconfig['warn about non-e-resource records']
    if rec.is_e_rec? == 'no'
      rec.warnings << 'Not an e-resource record?'
    end
  end

  if thisconfig['warn about cat lang']
    catlangs = thisconfig['cat lang']
    reclang = rec.cat_lang
    unless catlangs.include?(reclang)
      rec.warnings << 'Not our language of cataloging'
    end
  end

  if thisconfig['write warnings to recs']
    if rec.warnings.size > 0
      rec.warnings.each { |w|
        add_marc_var_fields_replacing_values(rec, thisconfig['warning flag spec'], [{'[WARNINGTEXT]'=>w}])
        if thisconfig['log warnings']
          log << [rec.source_file, rec[idtag].value, w]
        end
      }
    end
  end

  if thisconfig['use id affix']
    myfix = thisconfig['id affix value']
    unless myfix == ''
      if thisconfig['affix type'] == 'suffix'
        rec[idtag].value += myfix
        if thisconfig['overlay matchpoint includes 019']
          f = rec['019']
          f.subfields.each { |sf| sf.value += myfix } if f
        end
      elsif thisconfig['affix type'] == 'prefix'
        rec[idtag].value = myfix + rec[idtag].value
        if thisconfig['overlay matchpoint includes 019']
          f = rec['019']
          f.subfields.each { |sf| sf.value = myfix + sf.value } if f
        end
      else
        raise ArgumentError, "'affix type' option in config.yaml must be either 'prefix' or 'suffix'" 
      end
    end
  end
  
  out_mrc.write(rec)
}

mynew = in_mrc.select { |r| r.diff_status == 'NEW' }
mychange = in_mrc.select { |r| r.diff_status == 'CHANGE' }
mystatic = in_mrc.select { |r| r.diff_status == 'STATIC' }

puts "#{mynew.size} new -- #{mychange.size} change -- #{mystatic.size} static"

if thisconfig['log warnings']
  log.close
end
