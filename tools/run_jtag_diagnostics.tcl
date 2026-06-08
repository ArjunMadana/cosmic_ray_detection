# run_jtag_diagnostics.tcl - Run detector control/telemetry over the JTAG VIO mailbox.
#
# Usage:
#   vivado -mode batch -source tools/run_jtag_diagnostics.tcl -tclargs 15 FF 3

load_features labtools

set hold_s 15
set pattern_name FF
set cycles 1
if {[llength $argv] >= 1} { set hold_s [lindex $argv 0] }
if {[llength $argv] >= 2} { set pattern_name [string toupper [lindex $argv 1]] }
if {[llength $argv] >= 3} { set cycles [lindex $argv 2] }
set program_first 0
if {[llength $argv] >= 4} {
    set program_first [expr {[string toupper [lindex $argv 3]] eq "PROGRAM"}]
}

array set pattern_cmd {
    FF 0
    00 1
    55 2
    AA 3
}
if {![info exists pattern_cmd($pattern_name)]} {
    puts "ERROR: pattern must be one of FF, 00, 55, AA"
    exit 1
}
set listen_only [expr {$cycles < 0}]
set raw_debug [expr {$cycles < -1}]

proc open_first_hw_target {} {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    set targets {}
    for {set attempt 0} {$attempt < 5} {incr attempt} {
        catch {refresh_hw_server}
        after 1000
        if {[catch {set targets [get_hw_targets]}]} {
            set targets {}
        }
        if {[llength $targets] != 0} {
            break
        }
        puts "Waiting for hardware target..."
    }
    if {[llength $targets] == 0} {
        puts "ERROR: No hardware targets reported by hw_server."
        disconnect_hw_server
        exit 1
    }
    set target [lindex $targets 0]
    puts "Opening hw_target: $target"
    catch {
        set_property PARAM.FREQUENCY 6000000 $target
        puts "Set JTAG target frequency to 6000000 Hz."
    }
    open_hw_target $target
}

proc parse_vio_value {value} {
    set value [string trim $value]
    if {[string match "0x*" $value] || [string match "0X*" $value]} {
        set value [string range $value 2 end]
    }
    scan $value %x out
    return $out
}

proc parse_probe_value {probe width} {
    set value [string trim [get_property INPUT_VALUE $probe]]
    if {[string match "0x*" $value] || [string match "0X*" $value]} {
        set value [string range $value 2 end]
        scan $value %x out
        return $out
    }

    set hex_digits [expr {($width + 3) / 4}]
    if {[string length $value] > $hex_digits && [regexp {^[01]+$} $value]} {
        scan $value %b out
    } else {
        scan $value %x out
    }
    return $out
}

proc hex_value {value width} {
    set digits [expr {($width + 3) / 4}]
    return [format "%0*X" $digits $value]
}

proc get_probe {vio names} {
    foreach name $names {
        set probe [get_hw_probes $name -of_objects $vio]
        if {[llength $probe] == 0} {
            set probe [get_hw_probes "*$name*" -of_objects $vio]
        }
        if {[llength $probe] != 0} {
            return [lindex $probe 0]
        }
    }

    puts "ERROR: VIO probe not found. Tried: $names"
    set available [get_hw_probes -of_objects $vio]
    if {[llength $available] != 0} {
        puts "Available VIO probes:"
        foreach p $available {
            puts "  $p"
        }
    }
    exit 1
}

proc require_output_probe {probe label} {
    set type [get_property TYPE $probe]
    if {$type ne "vio_output"} {
        puts "ERROR: $label is not a writable VIO output probe: $probe"
        exit 1
    }
}

proc describe_probe {label probe} {
    set type [get_property TYPE $probe]
    puts "Bound $label: $probe ($type)"
}

open_first_hw_target
set device [lindex [get_hw_devices] 0]
current_hw_device $device

set proj_dir [file normalize "."]
set bitfile [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]
set ltxfile [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.ltx"]
if {$program_first} {
    if {![file exists $bitfile]} {
        puts "ERROR: Bitfile not found: $bitfile"
        exit 1
    }
    puts "Programming device before JTAG diagnostics: $bitfile"
    set_property PROGRAM.FILE $bitfile $device
    if {[file exists $ltxfile]} {
        puts "Using debug probes file: $ltxfile"
        set_property PROBES.FILE $ltxfile $device
    }
    set_property BSCAN_SWITCH_USER_MASK 1 $device
    program_hw_devices $device
    puts "Waiting for fabric/debug clocks before scanning VIO cores..."
    after 3000
}
if {[file exists $ltxfile]} {
    puts "Using debug probes file: $ltxfile"
    set_property PROBES.FILE $ltxfile $device
}
set_property BSCAN_SWITCH_USER_MASK 1 $device
refresh_hw_device $device

set vio_list [get_hw_vios -of_objects $device]
if {[llength $vio_list] == 0} {
    puts "ERROR: No VIO cores found. Rebuild with build_jtag_mailbox_board.bat and program with program_board.bat."
    exit 1
}
set vio [lindex $vio_list 0]
puts "Using VIO: $vio"

set p_tx_data  [get_probe $vio {vio_tx_data}]
set p_tx_seq   [get_probe $vio {vio_tx_seq}]
set p_tx_valid [get_probe $vio {vio_tx_valid}]
set p_cmd_seen [get_probe $vio {vio_cmd_seen_seq}]
set p_cmd_data [get_probe $vio {vio_cmd_data}]
set p_cmd_seq  [get_probe $vio {vio_cmd_seq}]
set p_tx_ack   [get_probe $vio {vio_tx_ack_seq}]

describe_probe "tx_data" $p_tx_data
describe_probe "tx_seq" $p_tx_seq
describe_probe "tx_valid" $p_tx_valid
describe_probe "cmd_seen" $p_cmd_seen
describe_probe "cmd_data" $p_cmd_data
describe_probe "cmd_seq" $p_cmd_seq
describe_probe "tx_ack" $p_tx_ack

require_output_probe $p_cmd_data "command data"
require_output_probe $p_cmd_seq "command sequence"
require_output_probe $p_tx_ack "TX ack sequence"

puts "Clearing VIO command/ack outputs..."
set_property OUTPUT_VALUE 00 $p_cmd_data
set_property OUTPUT_VALUE 00 $p_cmd_seq
set_property OUTPUT_VALUE 0000 $p_tx_ack
commit_hw_vio $vio
after 100

set cmd_seq 0
set last_ack 0
set line ""
set temp_count 0

proc send_byte {byte} {
    global vio p_cmd_data p_cmd_seq cmd_seq p_cmd_seen
    set cmd_seq [expr {($cmd_seq + 1) & 255}]
    set_property OUTPUT_VALUE [hex_value $byte 8] $p_cmd_data
    set_property OUTPUT_VALUE [hex_value $cmd_seq 8] $p_cmd_seq
    commit_hw_vio $vio

    set deadline [expr {[clock milliseconds] + 2000}]
    while {[clock milliseconds] < $deadline} {
        refresh_hw_vio $vio
        set seen [parse_probe_value $p_cmd_seen 8]
        if {$seen == $cmd_seq} {
            return
        }
        after 10
    }
    puts "WARNING: command byte was not acknowledged by FPGA: $byte"
}

proc send_text {text} {
    for {set i 0} {$i < [string length $text]} {incr i} {
        send_byte [scan [string index $text $i] %c]
    }
}

proc read_jtag_byte {} {
    global vio p_tx_valid p_tx_seq p_tx_data p_tx_ack last_ack raw_debug

    refresh_hw_vio $vio
    set raw_valid [string trim [get_property INPUT_VALUE $p_tx_valid]]
    set raw_seq [string trim [get_property INPUT_VALUE $p_tx_seq]]
    set raw_data [string trim [get_property INPUT_VALUE $p_tx_data]]
    set valid [parse_probe_value $p_tx_valid 1]
    set seq [parse_probe_value $p_tx_seq 16]
    if {$valid == 0 || $seq == $last_ack} {
        after 10
        return -1
    }

    set byte [parse_probe_value $p_tx_data 8]
    if {$raw_debug} {
        puts [format "RAW valid=%s seq=%s data=%s -> seq=%d byte=0x%02X" \
            $raw_valid $raw_seq $raw_data $seq $byte]
    }
    set_property OUTPUT_VALUE [hex_value $seq 16] $p_tx_ack
    commit_hw_vio $vio
    set last_ack $seq
    return $byte
}

proc wait_for_ready {timeout_seconds} {
    set deadline [expr {[clock milliseconds] + ($timeout_seconds * 1000)}]
    set line ""
    while {[clock milliseconds] < $deadline} {
        set byte [read_jtag_byte]
        if {$byte < 0} {
            continue
        }
        if {$byte == 10} {
            set clean [string trim $line]
            if {$clean eq "READY"} {
                puts "Saw READY over JTAG."
                return 1
            }
            set line ""
        } elseif {$byte != 13} {
            append line [format "%c" $byte]
        }
    }
    puts "WARNING: Did not see READY over JTAG before command send."
    return 0
}

proc wait_for_line {pattern timeout_seconds echo_line} {
    set deadline [expr {[clock milliseconds] + ($timeout_seconds * 1000)}]
    set line ""
    while {[clock milliseconds] < $deadline} {
        set byte [read_jtag_byte]
        if {$byte < 0} {
            continue
        }
        if {$byte == 10} {
            set clean [string trim $line]
            if {$echo_line && $clean ne ""} {
                puts $clean
            }
            if {[string match $pattern $clean]} {
                return 1
            }
            set line ""
        } elseif {$byte != 13} {
            append line [format "%c" $byte]
        }
    }
    puts "WARNING: Did not see line matching '$pattern' over JTAG."
    return 0
}

if {$listen_only} {
    puts "Listen-only mode for $hold_s seconds; no JTAG commands will be sent."
} else {
    puts "Resetting board FSM over JTAG..."
    send_text "X"
    puts "Waiting for READY after reset..."
    wait_for_line "READY" 20 1
    set hold_text [format "%04d" $hold_s]
    puts "Sending hold command: H$hold_text"
    send_text "H$hold_text\n"
    wait_for_line "INTERVAL:*" 10 1
    puts "Sending pattern command: P$pattern_cmd($pattern_name)"
    send_text "P$pattern_cmd($pattern_name)\n"
    wait_for_line "PATTERN:*" 10 1
    puts "Sending go command: G"
    send_text "G"
}

set out_dir [file normalize "data/diagnostics"]
file mkdir $out_dir
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set out_path [file normalize "$out_dir/jtag_live_$stamp.txt"]
set fh [open $out_path w]
puts "Writing JTAG telemetry to: $out_path"

if {$listen_only} {
    set timeout_ms [expr {[clock milliseconds] + ($hold_s * 1000)}]
} else {
    set timeout_ms [expr {[clock milliseconds] + (($hold_s + 90) * 1000 * $cycles)}]
}

while {[clock milliseconds] < $timeout_ms && ($listen_only || $temp_count < $cycles)} {
    set byte [read_jtag_byte]
    if {$byte >= 0} {
        puts -nonewline $fh [format "%c" $byte]
        puts -nonewline [format "%c" $byte]

        if {$byte == 10} {
            set clean [string trim $line]
            if {[string match "TEMP:*" $clean]} {
                incr temp_count
            }
            set line ""
        } elseif {$byte != 13} {
            append line [format "%c" $byte]
        }
    }
}

close $fh
puts ""
puts "Captured TEMP records: $temp_count / $cycles"
puts "Output: $out_path"

close_hw_target
disconnect_hw_server
