gem "minitest"

ENV["thermo_run_mode"] = 'testing'
#ENV["thermo_run_mode"] = 'production'

require 'minitest/autorun'
require '../thermoclient.rb'
require 'fileutils'
require 'chronic'
require 'debugger'

VALID_BOOT_JSON_ORIG = 'valid-thermo-boot.json.orig'
VALID_CONFIG_JSON_ORIG = 'backbedroom.json.orig'
VALID_EXTREME_TEMP_CONFIG_JSON_ORIG = 'backbedroom_hot.json.orig'
VALID_TEMP_OVERRIDE_CONFIG_JSON_ORIG = 'backbedroom-override.json.orig'
VALID_CHANGED_CONFIG_JSON_ORIG = 'backbedroom.json.changed.orig'
VALID_IMMEDIATE_CONFIG_JSON_ORIG = 'backbedroom.json.immediate.orig'
VALID_IMMEDIATE_SECOND_CONFIG_JSON_ORIG = 'backbedroom.json.immediate_second.orig'
VALID_TEMP_OVERRIDE_IMMEDIATE_CONFIG_JSON_ORIG = 'backbedroom-override-immediate.json.orig'
VALID_TEMP_OVERRIDE_OFF_CONFIG_JSON_ORIG = 'backbedroom-override-off.json.orig'
INVALID_MALFORMED_CONFIG_JSON_ORIG = 'invalid-malformed-backbedroom.json.orig'
INVALID_MISSING_ELEMENT_CONFIG_JSON_ORIG = 'invalid-missing-element-backbedroom.json.orig'
INVALID_MALFORMED_BOOT_JSON_ORIG = 'invalid-malformed-thermo-boot.json.orig'
INVALID_MISSING_ELEMENT_BOOT_JSON_ORIG = 'invalid-missing-elements-thermo-boot.json.orig'
# this file is made available to a webserver at the path specified in 
# VALID_BOOT_JSON_ORIG for config_url and config_url_watch.
# This is done by setup/teardown routines below
# This file should NOT exist in between testing sessions
CONFIG_JSON = 'backbedroom.json'

DIR_ROOT =(rand*10000000).to_i
DIR_THERM = "./sys/bus/w1/devices/28-#{DIR_ROOT}"
class ThermoTestError < RuntimeError; end

class TestThermostatReads < Minitest::Test
  def setup
    FileUtils.cp(VALID_BOOT_JSON_ORIG, Thermo::BOOT_FILE_NAME)
    FileUtils.cp(VALID_CONFIG_JSON_ORIG, CONFIG_JSON)
    if Dir::pwd == "/" || Dir::pwd.match(/[a-z]:\/$/)
      raise ThermoTestError.new("Can't run this test from root folder!!")
    end
    FileUtils::mkdir_p(DIR_THERM)
  end
  
  def teardown
    if Dir::pwd == "/" || Dir::pwd.match(/[a-z]:\/$/)
      raise ThermoTestError.new("Can't run this test from root folder!!")
    end
    FileUtils::rm_rf(DIR_THERM)
    FileUtils.safe_unlink(Thermo::BOOT_FILE_NAME)
    FileUtils.safe_unlink(CONFIG_JSON)
    raise Thermo::ConfigFileNotFound if File.exist?(Thermo::BOOT_FILE_NAME)
    raise Thermo::ConfigFileNotFound if File.exist?(CONFIG_JSON)
  end

  # test that thermostat reading commands are sent to hardware 
  def test_heater_thermostat_reader
    # TODO use a totally valid thermostat input file
    # we set up a semi-valid thermostat input file
    # temp is hardcoded to 24.495 celsius
    File::open(DIR_THERM+"/w1_slave", "w+") do |w1_slave|
      w1_slave.puts("39 4393- 219392 4ds, YES")
      w1_slave.puts("DK2 DKSJJ 59KS DK2 t=24495")
    end
    thermostat = Thermo::Thermostat.new
    thermostat.test_hw_temp_root_dir = '.'
    assert_equal 24.495, thermostat.get_hw_temp_c
  end
end

class TestThermoClient < Minitest::Test
  def setup
    FileUtils.cp(VALID_BOOT_JSON_ORIG, Thermo::BOOT_FILE_NAME)
    FileUtils.cp(VALID_CONFIG_JSON_ORIG, CONFIG_JSON)
  end
  
  def teardown
    FileUtils.safe_unlink(Thermo::BOOT_FILE_NAME)
    FileUtils.safe_unlink(CONFIG_JSON)
    raise Thermo::ConfigFileNotFound if File.exist?(Thermo::BOOT_FILE_NAME)
    raise Thermo::ConfigFileNotFound if File.exist?(CONFIG_JSON)
  end

## Unit tests

  def test_configuration_loader
    config = Thermo::Configuration.new
    assert_equal JSON.parse(IO.read(VALID_BOOT_JSON_ORIG)), config.boot
    assert_equal JSON.parse(IO.read(VALID_CONFIG_JSON_ORIG)), config.config
    ## TODO test that configuration fails to load bad config files
    # options = {:config_file => "}
    # config = Thermo::Configuration.new(options)
  end

  def test_run_mode_is_testing
    assert_equal "testing", ENV["thermo_run_mode"]
    assert_equal "testing", Thermo::RUN_MODE
  end

## Operating tests

  # we verify (as best as possible) that all the hardware 
  # initialization commands would be sent to the
  # command line correctly during production without actually
  # sending them to the command line
  def test_hardware_initializes_correctly
    thermostat = Thermo::Thermostat.new(:debug=>true)
    cur_time = thermostat.current_time
    expected_cmds = Thermo::INITIALIZE_HEATER_HARDWARE
    cmds = thermostat.command_line_history
    # we extract only expected cmds from returned cmds - if an expected 
    # command is missing we will get an error.
    # we don't care if there are more commands than we are expecting
    assert_equal expected_cmds, cmds[cur_time]-(cmds[cur_time]-expected_cmds)
  end

  # verify that during heater operation correct commands are
  # sent to hardware via command line
  def test_heater_sends_hardware_commands_correctly
    # heater should be off and stay off, relay command "off" sent
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("1/19/25 4:31 am")
    cur_temp = 65
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_equal({cur_time => Thermo::HEATER_OFF_CMD}, thermostat.command_line_history)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert_equal 62, thermostat.goal_temp_f
    # heater should turn on w/hardware
    cur_temp = 61
    cur_time = Chronic.parse("1/19/25 4:37:05 am")
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    expected_cmds = Thermo::HEATER_ON_CMD
    cmds = thermostat.command_line_history
    # we extract only expected cmds from returned cmds - if an expected 
    # command is missing we will get an error.
    # we don't care if there are more commands than we are expecting
    assert_equal expected_cmds, cmds[cur_time]-(cmds[cur_time]-expected_cmds)
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 62, thermostat.goal_temp_f
  end

  
## Test operating limits control from thermostat

# Test invalid files and inputs
# Test malformed JSON config files
# Test invalid input from thermometer

  # show that we raise exceptions when we get bad json config files
  def test_invalid_boot_json_file
    invalid_config_file = INVALID_MALFORMED_BOOT_JSON_ORIG
    FileUtils.cp(invalid_config_file, Thermo::BOOT_FILE_NAME)
    assert_raises(Thermo::InitializeFailed) {thermostat = Thermo::Thermostat.new}
    invalid_config_file = INVALID_MISSING_ELEMENT_BOOT_JSON_ORIG
    FileUtils.cp(invalid_config_file, Thermo::BOOT_FILE_NAME)
    thermostat = nil
    assert_raises(Thermo::InitializeFailed) {thermostat = Thermo::Thermostat.new}
  end

  def test_invalid_config_json_file
    FileUtils.cp(INVALID_MALFORMED_CONFIG_JSON_ORIG, CONFIG_JSON)
    assert_raises(Thermo::InitializeFailed) {thermostat = Thermo::Thermostat.new}
    
#    thermostat = Thermo::Thermostat.new
#    puts thermostat.configuration.config.inspect
    # test invalid config file on boot fails correctly
    FileUtils.cp(VALID_CONFIG_JSON_ORIG, CONFIG_JSON)
    # test invalid config file during running operations fails
    assert_silent {thermostat = Thermo::Thermostat.new({:throw=>true})}
  end

  # Heater should be on but it has exceeded max allowable temp
  def test_heater_turns_off_when_over_max_safe_temperature
    # Testing scenario:
    #   Time: 9/30/16 10:01 am
    #   Room temp: 90
    #   Initial Heater state: [test both]
    #   Max allowable temp: 80
    #   Heater running since: 9:50 am
    #   Heater hysteresis state: false
    #   Heater running too long: false
    #   Outcomes: Heater should be off
    #   Goal temp: 90 (extreme config file 10am-6pm)

    # try these tests once with heater turned on and then with heater turned off
    [true,false].each do |heater_starts_on|
      # We use a different config file that has extreme temp settings
      FileUtils.cp(VALID_EXTREME_TEMP_CONFIG_JSON_ORIG, CONFIG_JSON)
      thermostat = Thermo::Thermostat.new
      cur_time = Chronic.parse("9/30/16 10:01 am")
      temp_set_time = heater_starts_on ? Chronic.parse("9/30/16 9:50 am") : cur_time
      cur_temp = 77
      assert_set_and_test_time_temp(temp_set_time, cur_temp, thermostat)
      thermostat.set_heater_state(heater_starts_on, 62)
      assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
      temp_set_time = heater_starts_on ? Chronic.parse("9/30/16 9:50 am") : nil
      assert_heater_state_time({:heater_on => heater_starts_on, :last_on_time => temp_set_time}, thermostat)
      cur_temp = 90
      assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
      assert_equal 62, thermostat.goal_temp_f
      assert !thermostat.in_hysteresis?
      assert !thermostat.heater_on_too_long?
      assert thermostat.current_temp_too_hot_to_operate?
      assert !thermostat.heater_safe_to_turn_on?
      thermostat.process_schedule
      assert !thermostat.in_hysteresis?
      assert thermostat.current_temp_too_hot_to_operate?
      assert !thermostat.heater_on_too_long?
      assert !thermostat.heater_safe_to_turn_on?
      assert_heater_state_time({:heater_on => false, :last_on_time => temp_set_time}, thermostat)
      assert_equal 90, thermostat.goal_temp_f
    end
  end

# Test hysteresis (heater should turn on except that it was too recently on)
  def test_heater_turns_off_after_running_too_long
    # Testing scenario:
    #   Time: 8/31/15 8:47:59 pm
    #   Room temp: 44
    #   Initial Heater state: off
    #   Hysteresis window: 6 minutes 
    #    \=>(can't turn on heater after turning it off for 6 min)
    #   Heater running since: 8:43:22 pm
    #   Heater hysteresis state: true
    #   Outcomes: Heater should be off
    #   Goal temp: 70 (7pm-11pm)
    thermostat = Thermo::Thermostat.new
    temp_set_time = Chronic.parse("8/31/15 8:43:22 pm")
    cur_time = Chronic.parse("8/31/15 8:47:59 pm")
    cur_temp = 44
    assert_set_and_test_time_temp(temp_set_time, cur_temp, thermostat)
    thermostat.set_heater_state(true, 68)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => true, :last_on_time => temp_set_time}, thermostat)
    assert_equal 68, thermostat.goal_temp_f
    assert thermostat.in_hysteresis?
    assert !thermostat.heater_on_too_long?
    assert !thermostat.current_temp_too_hot_to_operate?
    assert !thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert thermostat.in_hysteresis?
    assert !thermostat.heater_on_too_long?
    assert !thermostat.current_temp_too_hot_to_operate?
    assert !thermostat.heater_safe_to_turn_on?
    assert_heater_state_time({:heater_on => false, :last_on_time => temp_set_time}, thermostat)
    assert_equal 70, thermostat.goal_temp_f
  end


# Test heater turns off after running for too long a period
# The heater should be shut off, the last on time should be current
# After shutting down, the heater isn't considered as running too long anymore
# BUT the heater IS now in hysteresis which will keep it off for that period
  def test_heater_turns_off_after_running_too_long
    # Testing scenario:
    #   Time: 4/6/13 8:32:33 pm
    #   Room temp: 49
    #   Initial Heater state: on
    #   Max heater operation time: 59 minutes
    #   Heater running since: 7:32 pm
    #   Heater hysteresis state: false
    #   Outcomes: Heater should be off
    #   Goal temp: 70 (7pm-11pm)
    thermostat = Thermo::Thermostat.new
    temp_set_time = Chronic.parse("4/6/13 7:32 pm")
    cur_time = Chronic.parse("4/6/13 8:32:33 pm")
    cur_temp = 49
    assert_set_and_test_time_temp(temp_set_time, cur_temp, thermostat)
    thermostat.set_heater_state(true, 68)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => true, :last_on_time => temp_set_time}, thermostat)
    assert_equal 68, thermostat.goal_temp_f
    assert thermostat.heater_on_too_long?
    assert !thermostat.in_hysteresis?
    assert !thermostat.heater_safe_to_turn_on?
    assert !thermostat.current_temp_too_hot_to_operate?
    thermostat.process_schedule
    assert !thermostat.heater_on_too_long?
    assert thermostat.in_hysteresis?
    assert !thermostat.current_temp_too_hot_to_operate?
    assert !thermostat.heater_safe_to_turn_on?
    assert_heater_state_time({:heater_on => false, :last_on_time => cur_time}, thermostat)
    assert_equal 70, thermostat.goal_temp_f
  end

## Test valid operating behavior

# Functional test: Test sequences of heater on, achieving goal temp, heater off, temp cool off, heater on, etc

  # verify that if config file changes after it has been loaded, that the new configuration
  # values are used instead of the existing ones
  def test_when_config_file_changes
    # Testing scenario:
    #   Descr:  Load override config from URL and be in normal weekday mode
    #           Change the remote config file and check that behavior changes
    #   Time: 11/4/55 9:11 am
    #   Room temp: 22
    #   Initial Heater state: off
    #   Outcomes: Heater should be off
    #   Goal temp: 68 (6:30am - 10am)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("11/4/55 9:11 am")
    cur_temp = 70
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert_equal 68, thermostat.goal_temp_f
    
    # simulate changing the config file to a new one that has 6:30am-10am window 
    FileUtils.cp(VALID_CHANGED_CONFIG_JSON_ORIG, CONFIG_JSON)
    cur_time = Chronic.parse("11/4/55 9:17 am")
    cur_temp = 69
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 72, thermostat.goal_temp_f
  end

  # verify that "temp_override" function sets heater to a set goal and turns heater 
  # on/off correctly. Specifically the temporary goal should only apply during
  # the time window when the override is set. Thermostat should return to scheduled
  # weekday operation when override time is no longer within current time window
  def test_temp_override_on_function
    # Testing scenario:
    #   Descr:  Load override config from URL and be in normal weekday mode
    #           B/c time window for override not yet relevant
    #           Then we switch to override mode and check that behavior changes
    #           Then we advance the clock and verify override is still in effect
    #           Until the clock passes the window
    #   Time: 9/14/29 9:50 am
    #   Room temp: 49
    #   Temp_override: 9/14/29 10:15am
    #   Temp_override temp_f: 72
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 68 (6:30am - 10am)
    FileUtils.cp(VALID_TEMP_OVERRIDE_CONFIG_JSON_ORIG, CONFIG_JSON)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("9/14/29 9:50 am")
    cur_temp = 49
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 68, thermostat.goal_temp_f

    # advance the clock to 10:01
    # set heater temp to 65
    # verify heater turns off
    last_on_time = cur_time
    cur_time = Chronic.parse("9/14/29 10:01 am")
    cur_temp = 65
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off, and new goal temp should be 62
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert_equal 62, thermostat.goal_temp_f

    # advance clock to 10:15am
    # leave room temp at 65
    # schedule wants room at 62
    # temp_override wants room at 72
    # verify heater turns on b/c temp_override should be active
    cur_time = Chronic.parse("9/14/29 10:15 am")
    cur_temp = 65
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 72, thermostat.goal_temp_f

    # advance clock to 10:21:02am
    # bring room temp to 72.1
    # schedule wants room at 62
    # temp_override wants room at 72
    # verify heater turns off b/c temp_override correctly turns it off
    last_on_time = cur_time
    cur_time = Chronic.parse("9/14/29 10:21:02 am")
    cur_temp = 72.1
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert_equal 72, thermostat.goal_temp_f

    # advance clock to 5:51pm
    # bring room temp to 71.9
    # schedule wants room at 62
    # temp_override wants room at 72
    # verify heater turns on b/c temp_override correctly turns it on
    cur_time = Chronic.parse("9/14/29 5:51 pm")
    cur_temp = 71.9
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn on
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 72, thermostat.goal_temp_f

    # advance clock to 6:12pm
    # bring room temp to 75
    # schedule wants heater off due to schedule gap
    # temp_override wants room at 72
    # verify heater turns off
    last_on_time = cur_time
    cur_time = Chronic.parse("9/14/29 6:12 pm")
    cur_temp = 75
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn on
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert_equal nil, thermostat.goal_temp_f

    # advance clock to 7:01pm
    # bring room temp to 60
    # schedule wants room at 70
    # force temp_override to want room at 55
    # verify heater turns on b/c regular schedule turns it on
    cur_time = Chronic.parse("9/14/29 7:01pm")
    cur_temp = 60
    thermostat.configuration.config["temp_override"]["temp_f"] = 55
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn on
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 70, thermostat.goal_temp_f
  end

  def test_temp_override_on_function_corner_cases
    # Testing scenario:
    #   Descr:  Load override config from URL and be in normal weekday mode
    #           B/c time window for override not yet relevant
    #           Then we switch to override mode and check that behavior changes
    #           Then we advance the clock and verify override is still in effect
    #           Until the clock passes the window
    #   Time: 9/14/29 9:50 am
    #   Room temp: 49
    #   Temp_override: 9/14/29 10:15am
    #   Temp_override temp_f: 72
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 68 (6:30am - 10am)
    FileUtils.cp(VALID_TEMP_OVERRIDE_CONFIG_JSON_ORIG, CONFIG_JSON)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("9/14/29 9:50 am")
    cur_temp = 49
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 68, thermostat.goal_temp_f
    
    #Verify that if we set heater mode to immediate, goal temp to 78, temp to 73
    #heater turns on even though temp_override should turn it off
    cur_time = Chronic.parse("9/14/29 10:28 am")
    cur_temp = 73
    FileUtils.cp(VALID_TEMP_OVERRIDE_IMMEDIATE_CONFIG_JSON_ORIG, CONFIG_JSON)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 78, thermostat.goal_temp_f
    
    #Verify that if we set heater mode to off and temp to 70
    #heater turns off even though temp_override should turn it on (goal of 72)
    last_on_time = cur_time
    cur_time = Chronic.parse("9/14/29 10:37 am")
    cur_temp = 70
    FileUtils.cp(VALID_TEMP_OVERRIDE_OFF_CONFIG_JSON_ORIG, CONFIG_JSON)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert_equal nil, thermostat.goal_temp_f
    
  end

  # verify that "hold" function sets heater to a set goal and turns heater 
  # on/off correctly
  def test_immediate_on_function
    # Testing scenario:
    #   Descr: Load config from URL and be in daily config mode.
    #          Then we switch to immediate mode and check that behavior changes
    #   Time: 6/30/15 5:32 pm
    #   Room temp: 49
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 62 (10am-6pm)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("6/30/15 5:32 pm")
    cur_temp = 49
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 62, thermostat.goal_temp_f

    # change operation_mode to immediate 
    # verify that heater turns off
    FileUtils.cp(VALID_IMMEDIATE_CONFIG_JSON_ORIG, CONFIG_JSON)
    last_on_time = cur_time
    cur_time = Chronic.parse("6/30/15 5:40 pm")
    cur_temp = 52
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off, and new goal temp should be 44
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert !thermostat.goal_temp_f

    # move immediate/hold temp up to 66 and verify the heater goes on
    last_on_time = cur_time
    cur_time = Chronic.parse("6/30/15 5:47 pm")
    cur_temp = 50
    new_goal_temp_f = 66
    FileUtils.cp(VALID_IMMEDIATE_SECOND_CONFIG_JSON_ORIG, CONFIG_JSON)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off, and new goal temp should be 44
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal new_goal_temp_f, thermostat.goal_temp_f
    
  end

  # Heater should not turn on under any circumstances when "operation_mode" in 
  # config file is "off"
  def test_immediate_off_function
    # Testing scenario:
    #   Descr: Load config from URL and be in daily config mode.
    #          Then we switch to "off" mode and check that heater is off under 
    #          all circumstances
    #   Time: 2/22/19 8:32 pm
    #   Room temp: 69
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 70 (7pm-11pm)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("2/22/19 8:32 pm")
    cur_temp = 69
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 70, thermostat.goal_temp_f

    # change operation_mode to off
    # verify that heater turns off even at low temperatures
    FileUtils.cp(VALID_TEMP_OVERRIDE_OFF_CONFIG_JSON_ORIG, CONFIG_JSON)
    last_on_time = cur_time
    cur_time = Chronic.parse("2/22/19 8:39 pm")
    cur_temp = 44
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should turn off, and new goal temp should be nil
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert !thermostat.goal_temp_f

    # move room temp up to 71 and verify the heater stays off
    cur_time = Chronic.parse("2/22/19 8:45 pm")
    cur_temp = 71
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert thermostat.heater_safe_to_turn_on?
    # heater should remain off, and new goal temp should be nil
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => last_on_time}, thermostat)
    assert !thermostat.goal_temp_f
  end
  
  
  def test_heater_gets_good_boot_configuration
    thermostat = Thermo::Thermostat.new
    assert_equal 59, thermostat.max_heater_on_time_minutes
    assert_equal "6 minutes", thermostat.hysteresis_duration
    assert_equal 79, thermostat.max_temp_f
  end

  # Temp could be 62 (11pm-11:59pm) if "last match wins" 
  # rule is used and we want first match to win
  def test_first_match_in_schedule_wins
    # Testing scenario:
    #   Time: 4/4/18 11:00pm
    #   Room temp: 8
    #   Initial Heater state: off
    #   Outcomes: Heater should be on 
    #   Goal temp: 70 (7pm-11pm)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("4/4/18 11:00pm")
    cur_temp = 8
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    thermostat.process_schedule
    assert_equal 70, thermostat.goal_temp_f
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
  end

  # Make sure last block of time works when end_time is 12:00am
  # 12:00am actually signifies "tomorrow at 12:00am" in this case
  def test_last_time_window
    # Testing scenario:
    #   Time: 1/8/27 11:59pm
    #   Room temp: 55
    #   Initial Heater state: on
    #   Outcomes: Heater should be on 
    #   Goal temp: 62 (11pm-12am)
    thermostat = Thermo::Thermostat.new
    temp_set_time = Chronic.parse("1/8/27 11:45 pm")
    cur_time = Chronic.parse("1/8/27 11:59pm")
    cur_temp = 55
    assert_set_and_test_time_temp(temp_set_time, cur_temp, thermostat)
    thermostat.set_heater_state(true, 69)
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => true, :last_on_time => temp_set_time}, thermostat)
    assert_equal 69, thermostat.goal_temp_f
    thermostat.process_schedule
    assert_equal 62, thermostat.goal_temp_f
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
  end

  def test_thermostat_should_stay_off_early_morning
    # Testing scenario:
    #   Time: 12/1/13 5:14am
    #   Room temp: 68
    #   Initial Heater state: off
    #   Outcomes: Heater should be off 
    #   Goal temp: 62 (12:00am-6:30am)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("12/1/13 5:14am")
    cur_temp = 68
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    assert_equal 62, thermostat.goal_temp_f
  end

  def test_thermostat_should_turn_off_due_to_schedule_gap
    # Testing scenario:
    #   Time: 12/8/14 6:26pm
    #   Room temp: 50
    #   Initial Heater state: been on for 30 minutes
    #   Outcomes: Heater should be off 
    #   Goal temp: nil (6:00pm-7:00pm)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("12/8/14 6:26pm")
    cur_temp = 50
    heater_last_started_time = Chronic.parse("12/8/14 5:56pm")
    assert_set_and_test_time_temp(heater_last_started_time, cur_temp, thermostat)
    assert !thermostat.in_hysteresis?
    thermostat.set_heater_state(true, 62)
    assert thermostat.in_hysteresis?
    assert thermostat.heater_on?
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert !thermostat.in_hysteresis?
    assert_heater_state_time({:heater_on => true, :last_on_time => heater_last_started_time}, thermostat)
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => false, :last_on_time => heater_last_started_time}, thermostat)
    assert_equal nil, thermostat.goal_temp_f
    
    # Testing scenario, pt II:
    #   Time: 12/8/14 7:01pm
    #   Room temp: 50
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 70 (7:00pm-11:00pm)
    cur_time = Chronic.parse("12/8/14 7:01pm")
    cur_temp = 50
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert !thermostat.in_hysteresis?
    assert_heater_state_time({:heater_on => false, :last_on_time => heater_last_started_time}, thermostat)
    assert_equal nil, thermostat.goal_temp_f
    thermostat.process_schedule
    heater_last_started_time = cur_time 
    assert_heater_state_time({:heater_on => true, :last_on_time => heater_last_started_time}, thermostat)
    assert_equal 70, thermostat.goal_temp_f
  end

  def test_thermostat_should_turn_on
    # Testing scenario:
    #   Time: 12/1/17 5:19am
    #   Room temp: 60
    #   Initial Heater state: off
    #   Outcomes: Heater should be on
    #   Goal temp: 62 (12:00am-6:30am)
    thermostat = Thermo::Thermostat.new
    cur_time = Chronic.parse("12/1/17 5:19am")
    cur_temp = 60
    assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    assert !thermostat.in_hysteresis?
    assert_heater_state_time({:heater_on => false, :last_on_time => nil}, thermostat)
    thermostat.process_schedule
    assert_heater_state_time({:heater_on => true, :last_on_time => cur_time}, thermostat)
    assert_equal 62, thermostat.goal_temp_f
  end


  ## Assertion helpers 
  
  # checks that heater is on/off and was last running at correct time
  def assert_heater_state_time(options, thermostat)
    state = options[:heater_on]
    last_on_time = options[:last_on_time]
    assert_equal state, thermostat.heater_on?, "Heater should be #{state.inspect} but was #{thermostat.heater_on?}"
    assert_equal last_on_time, thermostat.heater_last_on_time, "Heater last on time should be #{last_on_time.inspect} but was #{thermostat.heater_last_on_time.inspect}"
  end
  
  # sets current time and temp in thermostat object
  # verifies these are actually set correctly
  def assert_set_and_test_time_temp(cur_time, cur_temp, thermostat)
    thermostat.override_current_time = cur_time
    assert_equal cur_time, thermostat.current_time, "Thermostat time should be #{cur_time.inspect} but was #{thermostat.current_time.inspect}"
    thermostat.override_current_temp_f = cur_temp
    assert_equal cur_temp, thermostat.current_temp_f, "Thermostat temp should be #{cur_temp.inspect} but was #{thermostat.current_temp_f}"
  end
  
  def assert_nothing_raised(&proc)
    assert false, "Not implemented yet"
  end
  
end
