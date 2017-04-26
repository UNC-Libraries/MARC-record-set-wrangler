require 'marc'
require 'json'

module MARC

  class Writer
    attr_reader :fh
  end
  
  class Record
    include Comparable
    attr_accessor :warnings
    attr_accessor :changed_fields
    attr_accessor :changed_ac_fields
    attr_accessor :elvl_ac
    attr_accessor :ac_action
    attr_accessor :overlay_point
    attr_accessor :ac_fields
    attr_accessor :source_file
    attr_accessor :diff_status

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
      @changed_ac_fields = []
      @changed_fields = []
      @ac_action = nil
      @elvl_ac = false
      # Tag(s) on which overlay could happen.
      # Expect one, but could be multiple, in which case you might want to make a warning happen
      # Elements of the array will be like:
      #  {'001' => '87654980'} (field on which overlay will happen, matching value)
      @overlay_point = []
      @ac_fields = []
      @source_file # Path to file record is in
      @diff_status = ''
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

    def delete_ebk_655s
      self.each_by_tag("655") do |f|
        if f.to_s =~ /\$a ?(Electronic book|E-?book)/i
          self.fields.delete(f)
        end
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
