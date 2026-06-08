# create_jtag_vio_ip.tcl - Create/update the VIO core used by the JTAG mailbox.

proc ensure_project_open {} {
    if {[catch {current_project}]} {
        set xpr [file normalize "cosmic_ray_detection.xpr"]
        if {![file exists $xpr]} {
            puts "ERROR: No project is open and cosmic_ray_detection.xpr was not found."
            return -code error
        }
        open_project $xpr
    }
}

ensure_project_open

set ip_name vio_jtag_mailbox
set ip_dir [file normalize "cosmic_ray_detection.srcs/sources_1/ip"]
set mailbox_rtl [file normalize "cosmic_ray_detection.srcs/sources_1/new/jtag_vio_mailbox.v"]

file mkdir $ip_dir

if {[llength [get_files -quiet $mailbox_rtl]] == 0} {
    add_files -fileset sources_1 $mailbox_rtl
}

set existing [get_ips -quiet $ip_name]
if {[llength $existing] == 0} {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
        -module_name $ip_name -dir $ip_dir
}

set ip [get_ips $ip_name]
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {6} \
    CONFIG.C_NUM_PROBE_OUT {3} \
    CONFIG.C_PROBE_IN0_WIDTH {8} \
    CONFIG.C_PROBE_IN1_WIDTH {16} \
    CONFIG.C_PROBE_IN2_WIDTH {1} \
    CONFIG.C_PROBE_IN3_WIDTH {12} \
    CONFIG.C_PROBE_IN4_WIDTH {1} \
    CONFIG.C_PROBE_IN5_WIDTH {8} \
    CONFIG.C_PROBE_OUT0_WIDTH {8} \
    CONFIG.C_PROBE_OUT1_WIDTH {8} \
    CONFIG.C_PROBE_OUT2_WIDTH {16} \
] $ip

generate_target all $ip
export_ip_user_files -of_objects $ip -no_script -sync -force -quiet
catch {save_project}

puts "JTAG VIO mailbox IP is ready: $ip_name"
