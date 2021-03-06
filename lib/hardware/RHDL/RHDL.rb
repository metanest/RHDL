#########################################################
# RHDL - Ruby Hardware Description Language
# 2/23/2002 Phil Tomson
# Copyright (C) 2002-2006 Phil Tomson
# Released under same license as Ruby
# #######################################################
# 
#require 'hardware/RHDL/Bit'
#require 'hardware/RHDL/Signal'
require 'Bit'
require 'Signal'
require 'process'
require 'EnumType'
#require 'ClkGen'

#NOTE: the following is done so that the rescue will catch
#TypeError when a String is 'multiplied' by a Symbol as in
# '0'*n.  If you need to convert a Symbol to an int, call to_i
if Symbol.method_defined? :to_int
  class Symbol
    undef_method :to_int
  end
end
module RHDL
$simTime = 0 #global simulation time
MAX_EVENTS_IN_DELTA = 100

class RHDL_SyntaxError < Exception
end


############################################################
# SignalManager - manage a design's signals (not used yet)
############################################################
class SignalManager
  @@signalList = []
  def initialize()
    @@signalList = []
  end

  def SignalManager.add(signal)
    @@signalList << signal
  end

end


#####################################################################
# Design - the user's model should be a subclass of Design
#
#####################################################################
#require 'hardware/RHDL/SimulationMgr'
#require 'hardware/RHDL/t_process'
require 'SimulationMgr'
require 't_process'
class Design
  
  def behavior
    @behavior
  end
  def behavior= b
    @behavior=b
  end
  def set_init &b
    @init = b
  end
  def set_behavior &b
    @behavior = b
  end

  #need this define_behavior for the case where the design has both
  #an init block and a behavior block.  In that case the init block 
  #is called in the context of the generated 'initialize' method
  #which in turn calls this instance_level define_behavior method:
  def define_behavior &b
    @behavior = b
  end

  class << self
    def get_init
      @__init
    end
    def init &b
      #NOTE: check_missing_methods here too?
      #remove method_missing here (or undefine it)
      @__init = b
      #puts "#{self}.instance_methods.sort: #{self.instance_methods.sort.join(',')}"

      begin
        #we need to instance_eval the block here to see if it might 
        #contain a define_behavior block.  But the problem with 
        #doing it here is that if we have a structural design defined
        #in the init block only, we'll find that the i/o signals are actually 
        #just returning Symbols because we can't get them hooked up until
        #we actually initialize an instance...  So we do the 
        #instance_eval here and get ready to rescue NoMethodError...
        instance_eval &b 
      rescue NoMethodError
        if $!.to_s =~ /Symbol/
          #NOTE: the create_accessor method further down below creates a 
          #class level method for each i/o/generic and returns a Symbol
          #in this context we don't care if the method call doesn't 
          #work yet... the init block will eventually be called 
          #in the generated 'initialize' method
          warn "...ignoring method call in this context: #{$!}"
        else
          #if it wasn't a Symbol, go ahead and re-raise
          raise
        end
      rescue TypeError
        if $!.to_s =~ /convert Symbol into Integer/
          warn "...ignoring method call in this context: #{$!}"
        else
          raise
        end
      end


    end
    def check_missing_methods
      unless missing_methods.empty?
        (inports + inoutports + outports + generics_hsh.keys ).each {|methid|
          missing_methods.delete_if {|mm| mm[0]==methid }
        }
        unless missing_methods.empty?
	  lines = []
          missing_methods.reverse.each {|mm|
	    unless lines.include? mm[1]
              puts "unknown identifier: #{mm[0]} at: #{mm[1]}"          
	      puts
	      lines << mm[1]
	    else 
	      next
	    end
          }
          raise RHDL_SyntaxError
        end
      end
    end

    def define_behavior(&b)
      #first check for wayward 'missing_methods':
      check_missing_methods
      @__behavior = b 
      #Undefine method_missing here so we can catch problems in the 
      #block passed to define_behavior 
      (class << self; self; end).send(:undef_method, :method_missing)
      #TODO: should also undef method_missing in init and other def behav
    end

    def set_behavior &b
      @__behavior = b
    end

    def behavior
      puts "calling #{self}.behavior!! @__behavior.class is: #{@__behavior.class}" if $DEBUG
      @__behavior
    end

    def run
      puts "in #{self}::run"
      puts "a is: #{a}, b is: #{b} "
      @__behavior.call
    end

    def inports
      @__inports ||=[]
    end

    def inoutports
      @__inoutports ||=[]
    end

    def outports
      @__outports ||=[]
    end

    def create_accessor attrib,init_val=nil
      #writer:
      class_eval {
	define_method("#{attrib}=".intern){|val|
	  instance_variable_set("@#{attrib}",val)
        }
      }

      unless init_val 
        init_val = 0
      end

      if init_val.class == String
        init_val = "\"#{init_val}\""
      end

      #reader:
      class_eval { #attribute reader
	define_method(attrib){
	  instance_variable_get("@#{attrib}") || init_val
        }
      }
    end

    def inputs *in_syms
      in_syms.each {|input|
        if input.class == Hash
	  #TODO: handle hashes as in the generics case?
	  # this useage would look something like:
	  #   inputs a=>0
	  # a way to set an initial value
        end
        inports << input
        create_accessor input
      }
    end

    #clock_sig: a subset of inputs (or just another input?)
    def clock_sig clk #just a single clock for now
      @clock = clk
      unless inports.include clk
        create_accessor clk
      end
    end

    def generics_hsh
      @generics_hsh ||= {}
    end

    def generics gen_hsh
      unless gen_hsh.kind_of? Hash
        raise RHDL_SyntaxError, "generics should be specified like: :<generic_name> => <generic_value>, ..."
      end
      #gen_hsh is now guaranteed to be a Hash
      generics_hsh.merge! gen_hsh
      gen_hsh.each {|k,v|
        create_accessor k,v
      }
    end

    def inouts *io_syms
      io_syms.each {|io|
        inoutports << io
        create_accessor io
      }
    end

    def outputs *out_syms
      out_syms.each {|output|
        outports << output
        create_accessor output
      }
    end

    def missing_methods
      @missing_methods ||=[]
    end

    #this is how we handle input/output signals so user doesn't have
    #to specify them as symbols:
    def method_missing meth_id, *args
      missing_methods << [meth_id, caller]
      puts "missing_methods now has: #{missing_methods.join(',')}" if $DEBUG
      meth_id
    end

  end #singleton class

  
  def inst_init #(inports=nil,outports=nil)
    puts "inst_init called!" if $DEBUG
    @simMgr = SimulationMgr.instance
    @simMgr.register_design(self)
    @per_step = nil
    @pid = 0
    @processHsh = {}
  end

  def wait_for(n)
    till = $simTime + n
    wait { till == $simTime }
  end

  ###############################################################
  # define_behavior - the block passed to define_behavior is where
  # you define the behavior of your model.
  ###############################################################
=begin
  def define_behavior(&b)
    @behavior = b
    puts "@behavior.class is: #{@behavior.class}"
  end
=end

  ###############################################################
  # per_step - The block passed to this method is run once per step
  # this is useful for things like clock generators with non 50% 
  # duty cycle.
  ###############################################################
  def per_step(&b)
    puts "per step called!" if $DEBUG
    @per_step = b
    puts "@per_step.class is: #{@per_step.class}" if $DEBUG
  end

  ###############################################################
  # process - works much like a VHDL process: 
  # if a signal in the sensitivity list has changed (has an event)
  # then the given block is call'ed.
  # If no sensitivity list is provided, the process block should be called
  # anyway - so, the sensitivity list will make simulation more efficent if
  # signals are provided in it.
  ###############################################################
  #WAS:
  #def process2(*sensitivityList, &block)
  #  if sensitivityList.length > 0
  #  sensitivityList.each {|signal|
  #    #look for signals in the list that have changed and if so
  #    #call the block
  #    if signal.event
  #	block.call if block
  #	return
  #    end
  #  }
  #  #TODO: Should the block be called in the absence of a sensitivity list?
  #  #(seems it has to be, what are the alternatives?)
  #  else
  #    block.call if block
  #  end
  #end

  def process(*sensitivityList, &block)
    unless @processHsh.has_key?(@pid)
      #was:@processHsh[@pid] = T_Process.new(&block)
      #now: the following works (and is EXPERIMENTAL)
      tmp_p = RHDL::Process.new(self,&block)
      @processHsh[@pid] = T_Process.new(&(tmp_p.block))

    end
    if sensitivityList.length > 0
      sensitivityList.each {|signal|
        #look for signals in the list that have changed and if so
        #call the block
        if signal.event
	        @processHsh[@pid].call 
	        break
        end
      }
      #In the absense of a sensitivity list, the block be called 
      #which is why it's more efficient to specify a sensitivity list
      #for a process
    else
      @processHsh[@pid].call 
    end
    @pid +=1 
  end

  ################################################################
  # step - step through simulation time given input values
  #        supplied in 'inHash' 
  # TODO: this method probably isn't needed anymore on Design since it has
  # been implemented in SimulationMgr
  ################################################################
=begin
  def step(inHash=nil,outHash=nil) #step through simulation time
    if inHash #set up new values on inputs
      inHash.each{|name,value|
        @inPorts[name].signal.assign value if @inPorts 
	@inPorts[name].signal.update 
      }
    end
    if @per_step
      puts "@per_step.call"
      @per_step.call
    end
    i = 0
    while Signal.deltaEvents?
      i+=1
      #until there aren't anymore events generated in the delta time
      Signal.clear_deltaEvents
      @behavior.call
      Signal.update_all
      if i > MAX_EVENTS_IN_DELTA
        puts "Oscillation detected!"
        exit
      end
    end
    puts "@behavior.call ==> #{i} times" if $DEBUG
    #Signal.clear_events
    report_current_state
    $simTime += 1 #increment the simulation time
    Signal.set_deltaEvents #so we get through the first time
    return @inPorts, @outPorts
  end 
=end
  def update
    @pid = 0
    @behavior.call if @behavior
  end

  def do_once_per_step
    @per_step.call if @per_step
  end

  def wait(&cond)
    @processHsh[@pid].wait(cond)
  end

  ###############################################################
  # report_current_state of all inputs and outputs
  ###############################################################
  def report_current_state
    str = "Inputs: "
    if @inPorts
    @inPorts.each { |name,signal|
       str << "#{name} = #{signal} " 
    }
    end
    str << " Outputs: "
    @outPorts.each { |name,signal|
      str << "#{name} = #{signal} "
    }
    puts str + " @#{$simTime}"
  end


  #############################################################
  # in_connect - connect input port to internal signal
  #############################################################
  def in_connect(extName, intSig)
    intSig.value = @inPorts[extName].value 
  end 

  #############################################################
  # out_connect - connect internal signal to output port 
  #############################################################
  def out_connect(extName, intSig)
    @outPorts[extName].value = intSig.value
  end

end

########################################################
# Port - used to define inputs and outputs to designs
#
########################################################
class Port
  attr_reader :signal
  def initialize(signal = nil)
    @signal = signal
  end
  ######################################################
  # connect - associates a signal with this port
  # ####################################################
  def connect(signal)
    @signal = signal
  end
  ######################################################
  # to_s - so we can print out values more easily
  # ####################################################
  def to_s
    @signal.to_s
  end
  ######################################################
  # method_missing - pass all unknown messages on to 
  #                  the Port's signal. (pass-the-buck
  #                  to the signal)
  ######################################################
  def method_missing(methID,*args)
    @signal.send(methID,*args)
  end

end

def Port(signal=nil)
  Port.new(signal)
end

def model &b
  klass = Class.new(RHDL::Design, &b)

  if klass.behavior
    puts "has behavior"
  end
  if klass.get_init
    puts "has init"
  end
  #check for errors:
  #model doesn't have init or behavior block:
  if !( klass.behavior || klass.get_init)
    puts "neither behavior or init"
    raise RHDL_SyntaxError,"Circuit has neither behavior block nor init block!"
  end

  #TODO:should probably check for duplicates in inputs, outputs lists
  #(not needed yet)

  klass.class_eval {
    define_method(:initialize) {|arg_hsh|
      #TODO: more error checking
      #first set the default generics:
      klass.generics_hsh.each {|k,v|
        if arg_hsh.has_key? k
          instance_variable_set("@#{k}".intern, arg_hsh[k])
        else 
  	  #default value
          instance_variable_set("@#{k}".intern, v)
        end
      }
      ports = (klass.inports + klass.inoutports + klass.outports)
      ports.each {|arg|
        if arg_hsh.has_key? arg
  	  instance_variable_set("@#{arg}".intern, arg_hsh[arg])
        else
  	  raise RHDL_SyntaxError,"No '#{arg}' argument given for #{self} (required argument missing)"
        end
      }
      #now check for bogus (non-existent) arguments:
      bogus_args = arg_hsh.keys - (ports + klass.generics_hsh.keys) 
      if bogus_args.length > 0
	raise RHDL_SyntaxError,"The following are not valid arguments for #{klass}: #{bogus_args.join(',')}"
      end

      puts "in initialize for #{klass} (from model)"
      if klass.get_init
        init_proc = self.class.get_init
        self.class.send(:define_method, :__do_init, &init_proc)
        m = self.method :__do_init
        set_init &m
        __do_init
      elsif klass.behavior
        behavior_proc = self.class.behavior
        puts "behavior_proc.class is: #{behavior_proc.class}"
        self.class.send(:define_method, :__do_behavior, &(self.class.behavior))
        meth = self.method :__do_behavior
        set_behavior &meth
      end
      inst_init
    } #end of initialize method def
  }
  return klass
end


end #RHDL module
