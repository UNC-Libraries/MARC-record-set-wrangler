require "net/http"

module ClassicCatalog
  class Lookup
    attr_reader :id
    attr_reader :url
    attr_reader :status
    attr_reader :rec_data
    attr_accessor :marc
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
#puts fields
        indexes = []
        fields.each do |f|
          if f =~ /^\s+/
            indexes << fields.index(f)
          end
        end
#puts indexes        
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
          fields.each {|f| f.gsub!(/(\|x\d{4}-) (\d{4})/, '\1\2')}
          @rec_data = fields
        else
          @rec_data = nil
        end
        @marc = nil
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
