require "net/http"

module ClassicCatalog
  class Lookup
    attr_reader :id
    attr_reader :url
    attr_reader :status
    attr_reader :rec_data
    attr_reader :valid_result

    def initialize(id)
      @id = id

      response = Net::HTTP.get_response(URI(self.url))
      @status = response.class.name

      if response.message == 'OK'
        pagerec = response.body
        pagerec = pagerec.gsub!(/^.*<pre>/m, '')
        pagerec = pagerec.gsub!(/<\/pre>.*/m, '')
        pagerec = pagerec.gsub!(/^LEADER /, 'LDR    ')
        fields = pagerec.split("\n")
        
        indexes = []
        fields.each do |f|
          if f =~ /^\s+/
            indexes << fields.index(f)
          end
        end
        
        if indexes.size > 0
          indexes.reverse!
          indexes.each do |i|
            prev = i - 1
            appendee = fields[prev]
            appendee.gsub!(/ +$/, '')
            thisclean = fields[i].gsub(/^ +/, ' ')
            replace = appendee + thisclean
            fields[prev] = replace
            fields.delete_at(i)
          end
        end
        @rec_data = fields
      else
        @rec_data = nil
      end
    end

    def new(id)
      self.initialize(id)
    end

    def under_authority_control?
      if self.valid?
        m = self.rec_data.select { |f| /^915.*\|9Under Authority Control/ === f }
        if m.size > 0
          return true
        else
          return false
        end
      else
        return false
      end
    end

    def valid?
      if self.valid_result
        return true
      else
        return false
      end
    end
  end
  
  class OCLCLookup < Lookup
    def initialize(oclc_num)
      @url = "http://webcat.lib.unc.edu/search?/o#{oclc_num}/o#{oclc_num}/1%2C1%2C1%2CB/marc&FF=o#{oclc_num}&1%2C1%2C"
      super(oclc_num)

      if self.rec_data.class.name == "Array"
        chkstr = Regexp.new("^(001|035).*#{oclc_num}")
        matchfields = self.rec_data.select { |f| chkstr === f }
        if matchfields.size > 0
          @valid_result = true
        else
          @valid_result = false
        end
      end
    end

    def new(oclc_num)
      self.initialize(oclc_num)
    end
  end

  
end

require 'marc'
require 'json'

module MARC

  class Record
    include Comparable
    attr_accessor :warnings
    attr_accessor :changed_fields
    attr_accessor :reasons_for_update
    attr_accessor :retain_based_on_update_reason
    attr_accessor :elvl_ac
    attr_accessor :existing_ac
    attr_accessor :overlay_point


    # call-seq:
    #   rec.countf(tag) => integer
    # Returns number of fields in the record that match the field tag given as an argument.
    # For example, in a record with two 246 fields:
    #    rec.countf(246) #=> 2
    # Regular expression syntax can be passed in. For example to find out how many subject headings:
    #    rec.countf('6..') #=> 2
    # While purely numeric tags can be passed in without quoting them, the regexp needs to be quoted.

    # creates array with all values of one or more subfields
    # in a field.
    # tag must be a string.
    # sf must be a string. one or more single character delimiters with no spaces.

    def initialize
      @fields         = FieldMap.new
      # leader is 24 bytes
      @leader         = ' ' * 24
      # leader defaults:
      # http://www.loc.gov/marc/bibliographic/ecbdldrd.html
      @leader[10..11] = '22'
      @leader[20..23] = '4500'
      @warnings = []
      @reasons_for_update = []
      @changed_fields = []
      @retain_based_on_update_reason = true
      @elvl_ac = false
      @under_ac_already = false
      @overlay_point = []
      @existing_ac = false
    end

    def <=>(another_record)
      self['001'].value <=> another_record['001'].value
    end

    def cat_lang
      catlang = self['040']['b']
      if catlang == nil
        return 'eng'
      else
        return catlang
      end
    end

    def encoding_level
      ldr = self.leader
      return ldr[17]
    end

    def workform_type
      ldr = self.leader
      rtb= ldr[6, 2] #rec_type & blvl bytes
      case rtb
      when /^a[acdm]/
        return "Books"
      when /^a[bis]/
        return "Continuing resources"
      when /^t/
        return "Books"
      when /^[cdij]/
        return "Music"
      when /^[ef]/
        return "Maps"
      when /^[gkor]/
        return "Visual materials"
      when /^m/
        return "Computer files"
      when /^p/
        return "Mixed Materials"
      end
    end

    def delete_fields_by_tag(mytag)
      self.each_by_tag(mytag) do |f|
        self.fields.delete(f)
      end
      return self
    end
    
    def get_019_vals
      vals = []
      the019s = self.find_all { |f| f.tag == '019' }
      if the019s.size > 0
        the019s.each do |f|
          f.subfields.each { |sf| vals << sf.value }
        end
      end
      return vals
    end
    
    def is_e_rec?
      e_ct = 0
      the007s = self.find_all {|f| f.tag == '007'}
      the007s.each do |f|
        e_ct += 1 if f.value =~ /^cr/
      end

      the006s = self.find_all {|f| f.tag == '006'}
      the006s.each do |f|
        e_ct += 1 if f.value =~ /^m/
      end

      if self.workform_type =~ /Maps|Visual materials/
        formbyte = 29
      else
        formbyte = 23
      end

      e_ct += 1 if self['008'].value[formbyte] =~ /[os]/
      
      if e_ct == 0
        return 'no'
      else
        return 'yes'
      end
    end
    
    def array_of_values(tag, sf)
      fs = self.fields(filter = tag)
      ss = sf.split(//)

      v = []
      fs.each do |f|
        ss.each {|c| v << f[c]}
      end
      v.compact
    end

    def countf(tag)
      fields = self.find_all {|f| f.tag =~ /^#{tag}/}
      return fields.size
    end #def countf(tag)

    # Returns value of 001 field
    def _001
      field = self.find {|f| f.tag =~ /^001/}
      field.value
    end #def _001

    #Create JSON version of record
    def create_json_record
      json_rec = JSON.pretty_generate(self.to_hash)
      return json_rec
    end

    def main_entry?
      field = self.find_all {|f| f.tag =~ /1[01][01]/}
      if field.size > 0
        return true
      else
        return false
      end
    end #main_entry?

    def count_paes
      field = self.find_all {|f| f.tag =~ /700/}
      field.size
    end #def count_paes

    def count_controlled_shs
      field = self.find_all {|f| f.tag =~ /^6(00|10|11|30|50|51)/}
      field.size
    end #def count_controlled_shs

    def count_uncontrolled_shs
      field = self.find_all {|f| f.tag =~ /^6(5[2-9]|[6-9])/}
      field.size
    end #def count_uncontrolled_shs

  end #class Record
end #module MARC
