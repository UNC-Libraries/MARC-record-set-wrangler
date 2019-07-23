module MarcWrangler
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

    def add_conditional_field_with_parameters(fspec)
      find_spec = fspec['find']
      add_specs = fspec['add']
      mappings = fspec['mappings']

      fields = Config.get_fields_by_spec(@rec.fields, [find_spec])
      fields.each do |f|
        mappings.each do |map|
          next unless f.to_s =~ /#{map['value']}/

          params = map.reject { |k, _| k == 'value' }
          add_specs.each do |add_spec|
            add_field_with_parameter([add_spec], [params])
          end
        end
      end
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
end
