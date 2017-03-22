$LOAD_PATH << '.'
require 'yaml'
require 'marc'
require 'marc_record'

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

# Clean IDs in both files if config says.
# Set up array of existing record ids for comparing sets
# Set record.overlay_point to idtag if there's a match on main record id
# NOTE: Since we are comparing original files, we don't need to add id suffixes until we output
#  the processed records.
ex_ids = []
if iconfig['clean ids']
  def clean_id(rec, tag)
    id = rec[tag].value
    newid = id.gsub(/^(oc[mn]|on)/, '').gsub(/ *$/, '').gsub(/\\$/, '')
    rec[tag].value = newid
    return rec
  end
  ex_mrc.each { |rec| clean_id(rec, idtag) ; ex_ids << rec[idtag].value }
  in_mrc.each { |rec| clean_id(rec, idtag) ; rec.overlay_point << idtag if ex_ids.include?(rec[idtag].value) }
end








