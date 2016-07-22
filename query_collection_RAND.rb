# coding: utf-8
# ruby 2.3
# runs on .mrc file
# usage:
# ruby wcm_RAND_query_coll_processing.rb

require "marc"
require "json"
require "csv"
require 'pp'

#  -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
#    SCRIPT INPUT
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# Incoming MARC records
mrcfile = "data/rand_orig1.mrc"

unless File.exist?(mrcfile)
  puts "\n\nERROR: #{mrcfile} is missing. Please check file names and run script again.\n\n"
  exit
end

# Prepares to create a log file if there are any warnings/errors
t = Time.now
timestring = t.strftime("%Y-%m-%d_%H-%M")
errs = CSV.open("output/RAND_processing_log.csv", 'wb')
#errs = CSV.open("output/RAND_processing_log_#{timestring}.csv", 'wb')
errs << ['001 value','Category', 'Subcat', 'Message']

randurllist = File.open("output/randurl.txt", 'wb')

elvl_score = {
  ' ' => 12, 
  'I' => 11,
  '1' => 10,
  'L' => 9,
  '2' => 8,
  '4' => 7,
  '7' => 6,
  'K' => 5,
  '3' => 4,
  '5' => 3,
  'M' => 2,
  '8' => 1,
  'J' => 0,
}

notautho = {"915" =>
            {"ind1" => ' ',
             'ind2' => ' ',
             'subfields' => [
               {'9' => 'NOTAUTHO'},
               {'3' => 'erescat'}
             ]
            }
           }

def get_fields(hrec, tag)
  return hrec['fields'].find_all { |f| f.has_key?(tag) }
end

def get_sf_values_detail(hrec, tag, sfdelim)
  subfields = []
  fields = get_fields(hrec, tag)
  fields.each do |f|
    mysfs = []
    f[tag]['subfields'].each do |sf|
      mysfs << sf[sfdelim] if sf.has_key?(sfdelim)
    end
    subfields << mysfs
  end
  return subfields
end

def get_sf_values_summary(hrec, tag, sfdelim)
  subfields = []
  fields = get_fields(hrec, tag)
  fields.each do |f|
    f[tag]['subfields'].each do |sf|
      subfields << sf[sfdelim] if sf.has_key?(sfdelim)
    end
  end
  return subfields
end
ids = {}

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# PHASE 1 - Exclude records based on format and clean up URLs
#         - Writes intermediate MARC file that is later read and deduplicated
#           based on fileurls data
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
marcwriter = MARC::Writer.new("output/rand_intermediate.mrc")

# Each record's unique, cleaned RAND URLs are added to fileurls, along with:
#  - ocn
#  - encoding level
#  - 005 value
#  - list of document IDs linked to by record
# These are used to determine which record to keep in the case of duplicates
fileurls = {}

reader = MARC::Reader.new(mrcfile)
for rec in reader
  hrec = rec.to_hash
  #  puts JSON.pretty_generate(hrec)

  # get 001 value first -- need it for reporting errors/warnings
  m001 = hrec['fields'][0]['001'].gsub!(/\D/,'')


  # check ldr values
  rectype = hrec['leader'][6]
  unless rectype =~ /[at]/
    errs << [m001, "Excluded", "LDR Record type not a or t", "Value in record = #{rectype}"]
    next
  end
    
  blvl = hrec['leader'][7]
  unless blvl == 'm'
    errs << [m001, "Excluded", "LDR Blvl not m", "Value in record = #{blvl}"]
    next
  end
  
  elvl = hrec['leader'][17]

  m005 = get_fields(hrec, '005')
  rec_timestamp = m005[0]['005']

  escore = 0
  
  m008 = get_fields(hrec, '008')
  m008_form = m008[0]['008'][23]
  case m008_form
  when 'o'
    escore += 5
  when 's'
    escore += 3
  end

  m006 = get_fields(hrec, '006')
  m006_cf = false
  m006_form = ''
  if m006.size > 0
    m006[0].each do |f|
      if f[1][0] == 'm'
        m006_cf = true
        m006_form << f[1][6]
      end
    end
  end
  if m006_form.size == 1
    case m006_form
    when 'o'
      escore += 3
    when 's'
      escore += 2
    when ' '
      escore += 1
    end
  elsif m006_form.size > 1
    errs << [m001, 'Warn', '006', "Multiple computer forms: #{m006_form}"] if m006_form.match(/[^os ]/)
  elsif m006.size == 0
    escore += 1 if m006_cf
  end

  m007 = get_fields(hrec, '007')
  m007_cr = false
  m007_types = ''
  m007_cform = ''
  if m007.size > 0
    m007[0].each do |f|
      mtype = f[1][0]
      m007_types << mtype
      if mtype == 'c'
        m007_cform << f[1][1]
      end
    end
  end
  escore += 2 if m007_cform.include?('r')

  m337a = get_sf_values_summary(hrec, '337', 'a')
  m337a.uniq!

  m338a = get_sf_values_summary(hrec, '338', 'a')
  m338a.uniq!

  
  if m337a.include?('unmediated')
    errs << [m001, "Excluded", "337", "Unmediated"]
    if m337a.include?('computer')
      errs << [m001, "Warn", "337", "Unmediated AND Computer -- which one is it?"]
    end
    next
  end

  if m337a.include?('computer')
    if m338a.include?('online resource') == false
      errs << [m001,'Exclude', '338', m338a.to_s]
      next
    end
  end

  gmd_er = get_sf_values_summary(hrec, '245', 'h').select { |e| e.match('electronic resource') }
  er_gmd = false
  er_gmd = true if gmd_er.size > 0
  escore += 3 if er_gmd
  
  if m337a.size == 0 && m338a.size == 0
    errs << [m001, 'Warn', 'Format/eScore', "Check/improve format coding. Included based on eScore=#{escore} (008form=#{m008_form}, 006form=#{m006_form}, 007form=#{m007_cform}, erGMD=#{er_gmd}"]
  end
    
  errs << [m001, 'Warn', '007', "Non-computer types: #{m007_types.to_s}"] if m007_types.match(/[^c]/)
  
  # -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
  # - Delete all 9XXs
  # - Add NOTAUTHO 915 based on LDR Elvl value
  # -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
  my9xxs = []
  hrec['fields'].each { |f| my9xxs << f if f.keys[0].start_with?('9') }
  my9xxs.each { |f| hrec['fields'].delete(f) }
  hrec['fields'] << notautho if elvl_score[elvl] < 11

  # -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
  # Process URLs per record
  # -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
  my856s = []
  hrec['fields'].each { |f| my856s << f if f.keys[0] == '856' }
  my856s.each { |f| hrec['fields'].delete(f) }

  # Clean URLs and reformat so that:
  #  - they work and point to most general description of the title on RAND site
  #  -- this means no separate URLs needed for language, format, errata, supplements, etc.
  #  -- because of this we are ignoring $3
  #  - they are consistent and can be deduplicated
  # Each 856's RAND URLs are sent to the record's urlhash, which enables us to write deduplicated
  #  URLs to record, one per 856.
  # Each record's unique URLs, along with m001, encoding level, and date from 005 are sent to
  #  file-level hash to enable us to make sure only one record (the highest encoding level, with
  #  005 timestamp as tiebreaker--newer preferred) is being written per title
  # Writes full list of cleaned RAND URLs to output for examination.
  # Warns about URLs that do not match the expected pattern
  urlhash = {}
  my856s.each do |of|
    randurlct = 0
    of['856']['subfields'].each do |sf|
      sf.each_pair do |k, v|
        if k == 'u'
          if v.index('rand.org')
            randurlct += 1
            v.gsub!('%5F', '_')
            v.gsub!('/;', '/')
            v.gsub!('https://', 'http://')
            v.gsub!('wwwcgi.rand.org', 'www.rand.org')
            v.gsub!('http://rand.org', 'http://www.rand.org')
            v.gsub!(/^(www\.|)rand\.org/, 'http://www.rand.org')
            v.gsub!(/^.*(http:\/\/www\.rand\.org)/, '\1')
            v.gsub!(/\/?#.*/,'')
            v.gsub!('/publications/', '/pubs/')
            v.gsub!('/AR/', '/annual_reports/')
            v.gsub!('/CAE/', '/aid_to_edu_docs/')
            v.gsub!('/CB/', '/commercial_books/')
            v.gsub!('/CF/', '/conf_proceedings/')
            v.gsub!('/CP/', '/corporate_pubs/')
            v.gsub!('/CT/', '/testimonies/')
            v.gsub!('/DB/', '/documented_briefings/')
            v.gsub!('/DRU/', '/drafts/')
            v.gsub!('/IP/', '/issue_papers/')
            v.gsub!('/JRA/', '/joint_reports-health/')
            v.gsub!('/MG/', '/monographs/')
            v.gsub!('/MR/', '/monograph_reports/')
            v.gsub!('/N/', '/notes/')
            v.gsub!('/OP/', '/occasional_papers/')
            v.gsub!('/occasionalp_apers/', '/occasional_papers/')
            v.gsub!('/P/', '/papers/')
            v.gsub!('/PE/', '/perspectives/')
            v.gsub!('/R/', '/reports/')
            v.gsub!('/RB/', '/research_briefs/')
            v.gsub!('/researchb_riefs/', '/research_briefs/')
            v.gsub!('/RGSD/', '/rgs_dissertations/')
            v.gsub!('/rgsd_issertations/', '/rgs_dissertations/')
            v.gsub!('/RM/', '/research_memoranda/')
            v.gsub!('/RP/', '/reprints/')
            v.gsub!('/RR/', '/research_reports/')
            v.gsub!('/TL/', '/tools/')
            v.gsub!('/TR/', '/technical_reports/')
            v.gsub!('/technicalr_eports/', '/technical_reports/')
            v.gsub!('/WP/', '/white_papers/')
            v.gsub!('/WR/', '/working_papers/')
            v.gsub!('/workingp_apers/', '/working_papers/')
            v.gsub!(/\/$/, '')
            v.gsub!('www.rand.org/content/dam/rand/pubs/', 'www.rand.org/pubs/')
            v.gsub!('www.rand.org/content/dam/pubs/', 'www.rand.org/pubs/')
            v.gsub!(/www\.rand\.org\/[a-z]+\/\d+\/pubs\//, 'www.rand.org/pubs/')
            v.gsub!(/\/index\d*\.html/, '')
            v.gsub!(/\.html *$/, '')
            v.gsub!(/(pubs\/[^\/]+\/).*\/([^\/]+)$/, '\1\2')
            v.gsub!(/\/RAND_/i, '/')
            v.gsub!(/(\.[a-zA-Z\-]+)?\.pdf *$/, '')
            v.gsub!(/\.data\.zip *$/, '')
            v.gsub!(/\.(\d+) *$/, 'z\1')
            v.gsub!(/\.(\d+-\d+) *$/, 'z\1')
            v.strip!
            uid = v.match(/^.*\/([^\/]+)$/)[1]
            urlhash[v] = uid
            randurllist << "#{v}\t#{m001}\n"
          end
        end
      end
    end
  end

  if urlhash.size == 0
    errs << [m001, 'Excluded', '856', 'No RAND URLs left for this record after cleaning']
    next
  else
    urlhash.each_pair do |k, v|
      furldata = {m001 => {
                     'elvlscore' => elvl_score[elvl],
                     'updated' => rec_timestamp,
                     'rec_ids' => urlhash.values.sort!
                   }
                 }
                     
      if fileurls[k]
        fileurls[k] << furldata
      else
        fileurls[k] = [furldata]
      end
      newfield = {'856' =>
                  {
                    'ind1' => '4',
                    'ind2' => '0',
                    'subfields' => [
                    ]
                  }
                 }
      sfu = { 'u' => k }
      newfield['856']['subfields'] << sfu
      if urlhash.size > 1
        mat = {'3' => v }
        newfield['856']['subfields'] << mat
      end
      hrec['fields'] << newfield
    end
  end
  
  newrec = MARC::Record.new_from_hash(hrec)
  marcwriter.write(newrec)
end
marcwriter.close

# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
# PHASE 2 - Read intermediate MARC file that is later read and deduplicated
#           based on fileurls data
# Deduplication concepts:
#  - Each record can contain 0 or more URLs
#  - Multiple URLs in a record should be for different document IDs
#  - RecID set = the set of document IDs represented in a given record (practically this should
#    be the same as the set of URLs, but a given document ID can be pointed to by a number of
#    different URL formats
#  - Records are considered to be DUPLICATES if they have identical RecID sets
#  - RecID cluster = All records with the same RecID set
#  -- EXAMPLE: Duplicates
#  --- rec1 has URLs for TR001 and MR035
#  --- rec2 has URLs for TR001 and MR035
#  --- rec1 and rec2 are duplicates
#  --- the record with the highest encoding level in the RecID cluster will be output
#  --- if all records in RecID cluster have the same encoding level, most recently updated
#      record (from 005) is output
#  -- EXAMPLE: Not quite duplicates
#  --- rec3 has URL for TR001
#  --- TR001 alone is a different RecID set than [TR001, MR035], so it isn't a clear duplicate
#  --- It's possible TR001 shouldn't be on some of these records, so a warning will be written
#      to the log file
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
ireader = MARC::Reader.new("output/rand_intermediate.mrc")
fwriter = MARC::Writer.new("output/rand_final.mrc")
for rec in ireader
  m001 = rec['001'].value

  urls = []
  rec.each_by_tag('856') do |f|
    f.find_all { |sf| sf.code == 'u' }.each { |u| urls << u.value }
  end

  recIDset = []
  urls.each { |u| recIDset << u.match(/^.*\/([^\/]+)$/)[1] }
  recIDset.sort!
  
  urls.each do |u|
    recs_with_url = fileurls[u] #array of hashes, one per record that contains this URL, key=OCN
    ct_recs_with_url = recs_with_url.size
    if ct_recs_with_url == 1
      # only one record contains this URL
      fwriter.write(rec)
    elsif ct_recs_with_url == 0
      errs << [m001, 'Error', 'Intermediate file record URL not in lookup of RAND URLs', u]
      next
    else
      # idhash allows us to find records in the RecID cluster, as well as other records
      #  containing docIDs from this recIDset
      idhash = {}

      recs_with_url.each do |rh|
        ocn = rh.keys[0]
        es = rh[ocn]['elvlscore']
        up = rh[ocn]['updated']
        id_rec = { ocn => {
                     'elvlscore' => es,
                     'updated' => up
                   }
                 }
        ids = rh[ocn]['rec_ids']
        if idhash[ids]
          idhash[ids] << id_rec
        else
          idhash[ids] = [id_rec]
        end
      end

      # The docIDs in this record only appear in this recID set
      # EXAMPLE:
      # - this record's rec_ID_set has [D1, D2]
      # - there are no other rec_ID_sets like:
      # -- [D1]
      # -- [D1, D2, D500]
      # There is more than one record in this unique recID cluster
      if idhash.size == 1
        puts "\n\n#{m001} -- recIDset: #{recIDset.inspect}"
        pp(idhash)

        erec = []
        erank = 0
        cluster = []
        idhash[recIDset].each do |rec|
          myocn = rec.keys[0]
          cluster << myocn
          thiselvl = rec[myocn]['elvlscore']
          if thiselvl > erank
            erank = thiselvl
            erec = [myocn]
          elsif thiselvl == erank
            erec << myocn
          end
        end
        puts "ERANK: #{erank} - #{erec.inspect}"
        cluster.delete(m001)

        # encoding level winner and it is this record
        if erec.size == 1 && erec[0] == m001
          fwriter.write(rec)
          errs << [m001, 'Warn', 'Duplicates - highest encoding level chosen', cluster.join(' ')]
        # If encoding level winner and it's not this record, we don't do
        # anything here. This record is not written out and will be reported
        # as a duplicate when the best record from the cluster is written

        # Encoding level tie that includes this record
        elsif erec.size > 1 && erec.include?(m001)
          tsrec = []
          tsval = '00000'
          erecdata = idhash[recIDset].select { |r| erec.include?(r.keys[0]) }
          erecdata.each do |r|
            thisocn = r.keys[0]
            myts = r[thisocn]['updated']
            if myts > tsval
              tsval = myts
              tsrec = [thisocn]
            end
          end
          puts "TIMESTAMP: #{tsval} - #{tsrec}"
          if tsrec[0] == m001
            fwriter.write(rec)
            errs << [m001, 'Warn', 'Duplicates - latest update chosen to break encoding level tie', cluster.join(' ')]
          end
        end
      end
      # puts m001 if idhash.size > 1
      # pp(idhash) if idhash.size > 1
      # puts idhash.size if idhash.size > 1
    end
  end
end

fwriter.close

#pp(fileurls)
