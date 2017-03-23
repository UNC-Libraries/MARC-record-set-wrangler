$LOAD_PATH << '.'
require 'yaml'
require 'marc'
require 'marc_record'
require 'pp'

# Get a hash of your config
config = begin
           YAML.load(File.open('config.yaml'))
         rescue ArgumentError => e
           puts "Could not parse YAML config file: #{e.message}"
         end

# Set up in/out directories
in_dir = 'incoming_marc'
ex_dir = 'last_processed_marc_ORIG'
out_dir = 'output'

# Set up MARC writers
out_mrc = MARC::Writer.new("#{out_dir}/output.mrc")

# Find out what workflow we're dealing with and set workflow config
puts "\n\nEnter file segment/workflow you are processing (SPR2017, AMS, etc.):"
segment = gets.chomp
until config['workflows'].has_key?(segment)
  workflows = config['workflows'].keys.join(', ')
  puts "\n\nYou entered: #{segment}"
  puts "That file segment/workflow isn't configured." 
  puts "Please enter one of the following (CASE SENSITIVE):"
  puts workflows
  segment = gets.chomp
end
wconfig = config['workflows'][segment]
iconfig = config['institution']
idtag = iconfig['record id']['tag']

# Pull in our incoming and previously loaded MARC records
def get_recs(dir)
  recs = []
  Dir.chdir(dir)
  infiles = Dir.glob('*.mrc')
  infiles.each { |file| MARC::Reader.new(file).each { |rec| recs << rec } }
  puts "\n\nGrabbed #{recs.size} records from the following #{dir} files:"
  puts infiles
  Dir.chdir('..')
  return recs
end

in_mrc = get_recs(in_dir)

ex_mrc = get_recs(ex_dir)

# Set suffix if it's going to be used, otherwise it is blank string
suffix = ''
if iconfig['use id suffix']
  gsuffix = iconfig['global id suffix'] if iconfig.has_key?('global id suffix')
  wsuffix = wconfig['suffix'] if wconfig.has_key?('suffix')
  suffix += gsuffix if gsuffix
  suffix += wsuffix if wsuffix
puts "\n\nSuffix I will use is: #{suffix}"
end

def clean_id(rec, tag)
  id = rec[tag].value
  newid = id.gsub(/^(oc[mn]|on)/, '').gsub(/ *$/, '').gsub(/\\$/, '')
  rec[tag].value = newid
  return rec
end

# NOTE: Since we are comparing original files below, we don't need to add id suffixes
#  until we output the processed records.

# Clean IDs in if config says.
# Set up hash of existing records, keyed by idtag value, for comparing sets
# rec.overlay_point of {'019'=>x} here means:
#  - this record will be overlaid by incoming record with idtag value x
#  - incoming record's idtag value x presumably does NOT match this record's
#  -   idtag value
#  - the overlay will be on an 019$a value in the incoming record
ex_ids = {}

ex_mrc.each { |rec|
  clean_id(rec, idtag) if iconfig['clean ids']
  ex_ids[rec[idtag].value] = rec
}

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


# Clean IDs in if config says.
in_mrc.each { |rec|
  clean_id(rec, idtag) if iconfig['clean ids']
  # Set record.overlay_point of incoming record to idtag info if there's a match on main record id
  # Since this match relies on main record id being the same in incoming and existing
  #  records, also set record.overlay_point of existing record.
  if ex_ids.has_key?(rec[idtag].value)
    op = {idtag => rec[idtag].value}
    rec.overlay_point << op
    exrec = ex_ids[rec[idtag].value]
    exrec.overlay_point << op
  end

  if iconfig['overlay matchpoint includes 019']
    # Check for overlays between existing 001 and any 019$a in an incoming record
    get_019_matches(rec, idtag, ex_ids)
  end

  if iconfig['manipulate 019 for overlay']
    rec.overlay_point.each { |op| put_matching_019_sf_first(rec) if op.has_key?('019') }
  end

  if iconfig['flag overlay type']
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
    add_marc_var_fields_replacing_values(rec, iconfig['overlay type flag spec'], [{'[OVTYPE]'=>ovtype}])
  end

  if iconfig['warn about non-e-resource records']
    if rec.is_e_rec? == 'no'
      rec.warnings << 'Not an e-resource record?'
    end
  end

  if iconfig['write warnings to recs']
    if rec.warnings.size > 0
      rec.warnings.each { |w|
        add_marc_var_fields_replacing_values(rec, iconfig['warning flag spec'], [{'[WARNINGTEXT]'=>w}])
      }
    end
  end
  out_mrc.write(rec)
}











