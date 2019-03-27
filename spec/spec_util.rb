module SpecUtil
  def make_rec
    rec = MARC::Record.new
    rec << MARC::ControlField.new('008', ' ' * 40)
    return rec
  end
end
