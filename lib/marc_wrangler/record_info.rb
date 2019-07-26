module MarcWrangler
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
    attr_accessor :character_coding_scheme
    attr_accessor :reader
    attr_accessor :reader_index
    attr_accessor :marc_hash

    def initialize(id)
      @id = id
      @warnings = []
      @ovdata = []
      @overlay_type = []
    end

    def marc
      reader[reader_index]
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
end
