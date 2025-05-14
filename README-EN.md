# PCILeech FPGA DMA VMD Controller Simulation Project

<div align="right">
    <a href="README.md">中文</a> | <a href="README-EN.md">English</a>
</div>

## Disclaimer
This project is intended solely for research, education, and security testing purposes. The author does not encourage, support, or tolerate any use of this project for:
- Unauthorized access to or control of computer systems belonging to others;
- Bypassing, disabling, or countering any type of security, anti-cheat, or privacy protection mechanisms;
- Deploying this code in real environments for malicious activities, cheating, data theft, or destruction.

All code and technical details in this project are provided for anti-cheat system developers, security researchers, and hardware engineers to:
- Understand the working principles of DMA technology;
- Develop detection, countermeasure, and protection mechanisms;
- Test self-developed devices or experimental platforms.

Users must assume all legal and security responsibilities arising from their use of this code. The author and contributors are not responsible for any direct or indirect consequences resulting from this project.

## Project Overview

This project is a PCILeech FPGA implementation based on the Xilinx Artix-7 XC7A75T-FGG484 chip, specifically designed to simulate Intel RST VMD (Volume Management Device) controllers. PCILeech is a direct memory access (DMA) tool used for hardware security research and testing. The project achieves DMA access to modern systems by emulating an Intel RST VMD controller (Device ID: 9A0B).

## Latest Updates

- **VMD Controller Enhancement** - Full implementation of Intel RST VMD controller register set, supporting endpoint management and VMD-specific features
- **MSI-X Interrupt Improvement** - Implementation of automatic interrupt triggering and status monitoring, supporting VMD status change notifications and command completion notifications
- **NVMe Command Processing** - Support for basic NVMe command set, allowing the system to identify and operate virtual storage devices
- **Multi-Function Device Simulation** - Added support for simulating multiple PCI functions with configurable device types and capabilities
- **ACPI Path & Device Tree Simulation** - Implementation of realistic ACPI paths and device relationships for better system integration
- **Configurable BAR Addressing** - Support for customizable BAR addresses across multiple functions
- **Code Architecture Optimization** - Restructured top-level modules and interface definitions to improve code maintainability and stability
- **Module Interface Fix** - Fixed inconsistencies between pcileech_com and pcie_a7 module interfaces to ensure stable data flow
- **IP Core Optimization** - Fixed configuration space memory depth, supporting more complete VMD capability sets
- **Security Enhancement** - Added access pattern recognition and dynamic response control mechanisms
- **Stealth Mode Enhancement** - Improved TLP echo and scan detection functions with multiple response strategies and access pattern analysis
- **State Machine Improvements** - Fixed timeout handling logic for various module state machines
- **RW1C Register Implementation** - Added PCIe-compliant RW1C register modules specifically for handling status registers, improving compatibility
- **Redundancy Protection** - Enhanced register access pattern monitoring, optimized system response mechanisms, ensuring device stability
- **ZeroWrite4K Optimization** - Enhanced BAR implementation stealth capabilities with multiple response modes and adaptive counter recovery mechanisms

## Technical Principles

### VMD Controller Simulation

This project implements VMD controller simulation through the following methods:

1. **Device Disguise** - Disguises the FPGA device as an Intel RST VMD controller (Device ID: 9A0B), making the system recognize it as a trusted device
2. **PCIe Configuration Space Emulation** - Complete implementation of PCIe configuration space, including necessary capability structures
3. **MSI-X Interrupt Support** - Implementation of MSI-X interrupt mechanisms, supporting automatic triggering and status monitoring, ensuring compatibility with modern operating systems
4. **BAR Space Implementation** - Provides complete base address register (BAR) space implementation, supporting memory-mapped operations
5. **Dynamic Response Mechanism** - Intelligently identifies system query patterns and adaptively adjusts response strategies
6. **PCIe Bridge Emulation** - Defines the device type as a PCI-to-PCI bridge (Class Code: 060400), enhancing compatibility
7. **RW1C Register Standard Implementation** - PCIe-compliant RW1C register operations, ensuring correct status bit handling
8. **NVMe Command Support** - Implementation of basic NVMe management command sets, supporting system identification and operation of virtual storage devices

### Key Module Description

- **pcileech_75t484_x1_vmd_top.sv** - Top-level module, integrating all functional components, with added VMD-specific parameters
- **pcileech_fifo.sv** - FIFO network control module, responsible for data transmission and command processing
- **pcileech_com.sv** - Communication control module, handling communication between FT601 and the system, with fixed interface consistency issues
- **pcileech_ft601.sv** - FT601/FT245 controller module, handling USB communication
- **pcileech_pcie_a7.sv** - PCIe controller module, with fixed interface definitions and added PCIe status outputs
- **pcileech_pcie_cfg_a7.sv** - PCIe configuration module, handling Artix-7 CFG operations
- **pcileech_tlps128_cfgspace_shadow.sv** - Configuration space shadow module, supporting dynamic configuration responses
- **pcileech_tlps128_cfgspace_shadow_advanced.sv** - Enhanced configuration space, supporting access pattern analysis
- **pcileech_pcie_tlp_a7.sv** - TLP processing core, supporting echo and stealth modes
- **pcileech_bar_impl_vmd_msix.sv** - Implements BAR with MSI-X interrupt functionality, supporting VMD controllers and NVMe command processing
- **pcileech_bar_impl_zerowrite4k.sv** - Implements 4KB BAR with stealth functionality, supporting dynamic response and anomaly detection
- **pcileech_rw1c_register.sv** - Standard PCIe RW1C register implementation, providing status register operation functionality
- **pcileech_pcie_tlps128_status.sv** - PCIe TLP device status register module, using RW1C to process status bits
- **pcileech_tlps128_monitor.sv** - Access monitoring module, providing system stability support

## Project Structure

- `ip/` - Contains IP core files required for the project
  - Includes PCIe interfaces, FIFOs, BRAMs, and other IP cores
  - Latest version fixes memory depth and COE file format issues
  - Added pcileech_cfgspace_writemask.coe file, supporting correct RW1C register operations
- `src/` - Contains SystemVerilog source code files
  - Core function modules and top-level designs
  - Added VMD-specific top-level modules and support files
- `vivado_build.tcl` - Vivado build script, optimized to automatically recognize project names
- `vivado_generate_project_captaindma_75t.tcl` - Project generation script, fixing file reference inconsistencies

## IP Core Fix Notes

The latest version fixes the following IP core-related issues:

1. **Configuration Space Depth Extension** - Increased BRAM depth from 1024 to 2048, supporting complete VMD controller features
2. **Write Mask File Creation** - Added pcileech_cfgspace_writemask.coe file, implementing PCIe standard RW1C register functionality
3. **COE File Format Correction** - Added correct initialization format headers
4. **BAR Space Memory Extension** - Supports larger register areas, meeting MSI-X table and PBA requirements
5. **Vendor/Device ID Consistency** - Ensures all modules use unified vendor IDs and device IDs

## VMD Controller Functionality

The latest version significantly enhances VMD controller functionality:

1. **Complete Register Set Implementation** - Implemented all key registers of the Intel RST VMD controller:
   - Control Register - Used for VMD controller configuration
   - Status Register - Reflects the current controller status
   - Capabilities Register - Indicates supported controller features
   - Endpoint Count Register - Records the number of connected NVMe devices
   - Port Mapping Register - Manages VMD controller port allocation
   - Error Status/Mask Register - Error management and reporting

2. **MSI-X Interrupt Enhancement** - Implemented complete MSI-X interrupt handling mechanisms:
   - Status Change Interrupt Triggering - Automatically triggers interrupts when VMD controller status changes
   - Interrupt State Machine - Four-state interrupt handling state machine (IDLE/PREPARE/TRIGGER/WAIT)
   - Interrupt Error Monitoring - Automatic detection and recovery of interrupt errors

3. **NVMe Command Processing** - Supports basic NVMe management commands:
   - Get Log Page
   - Get Features
   - Identify
   - Automatic command completion and interrupt triggering

4. **Doorbell Register Implementation** - Supports NVMe standard doorbell registers, allowing systems to operate command queues

## Build Instructions

1. Install Xilinx Vivado Design Suite (2021.2)
2. Run the following command in Vivado Tcl Shell to generate the project:
   ```
   source vivado_generate_project_captaindma_75t.tcl -notrace
   ```
3. Generate the bitstream file:
   ```
   source vivado_build.tcl -notrace
   ```
   Note: Synthesis and implementation steps may take a long time.
4. Use the IP core validation script to check IP configuration consistency:
   ```
   source ip/verify_ip_consistency.tcl
   ```

## Script Fix Notes

The latest version fixes the following issues in the project generation and build scripts:

1. **Implementation Run Configuration** - Added complete impl_1 run creation and configuration code to the vivado_generate_project_captaindma_75t.tcl script, ensuring correct execution of implementation steps
2. **Project Generation and Build Consistency** - Ensures consistency between vivado_generate_project_captaindma_75t.tcl and vivado_build.tcl scripts in terms of implementation settings
3. **Report Configuration Improvement** - Added complete implementation report configurations, including DRC, timing, power, and resource utilization reports
4. **Parameter Passing Enhancement** - Optimized parameter passing methods between scripts, automatically recognizing project names
5. **File Reference Fix** - Fixed inconsistent file path references, ensuring all files are correctly imported
6. **Synthesis and Implementation Flow Upgrade** - Updated to Vivado 2022-compatible synthesis and implementation flows
7. **IP Core Upgrade Handling** - Added correct IP core upgrade handling logic

## Usage

1. Download the generated bitstream file to a supported FPGA development board
2. Connect the FPGA development board to the target system's PCIe slot
3. Use PCILeech software to communicate with the FPGA via USB interface for DMA operations
4. The system will recognize the FPGA as an Intel RST VMD controller, allowing DMA access

### Supported Operations

- Memory read/write operations
- Physical memory dumps
- DMA attack testing
- Hardware security research
- NVMe command emulation
- VMD controller advanced feature simulation
- NVMe virtual endpoint presentation

## Technical Specifications

- **FPGA Chip**: Xilinx Artix-7 XC7A75T-FGG484
- **PCIe Interface**: Gen2 x1
- **USB Interface**: High-speed data transfer via FT601
- **Emulated Device**: Intel RST VMD controller (Device ID: 9A0B)
- **PCI Class Code**: 060400 (PCI Bridge)
- **Memory Capacity**: Supports up to 2048 depth configuration space, 4K BAR space
- **RW1C Register Specifications**:
  - Supports up to 32-bit width, configurable default values
  - 4 operating states (normal, warning, recovery, error)
  - Access count supports up to 255 times
  - 16-bit access history pattern recording for monitoring access patterns
  - Built-in recovery mechanisms to prevent permanent lockups
- **MSI-X Specifications**:
  - Supports 16 interrupt vectors
  - Four-state interrupt handling state machine
  - Automatic triggering and monitoring mechanisms
  - Interrupt pending bit array (PBA) support
  - Vector error detection and recovery
- **VMD Controller Specifications**:
  - Supports up to 8 NVMe endpoints
  - Complete register set implementation
  - Compatible with Intel RST VMD protocol
  - Supports basic NVMe management commands
- **DMA Stability Assurance**:
  - Improved interface connections ensure smooth data flow
  - Module interface definition consistency fixes
  - Status signal and reset logic optimization
  - Supports high-speed data transfer
- **Stability Assurance**:
  - Adaptive timeout recovery mechanism
  - Multi-level exception handling fault-tolerant design
  - State machine-based dynamic response system
  - Redundant verification and status monitoring

## Security Features

The latest version adds the following security features:

1. **Access Pattern Analysis** - Monitors system access patterns to VMD devices, identifying abnormal scanning behaviors
2. **Dynamic Response Control** - Automatically adjusts response strategies based on access patterns, countering security detection
3. **TLP Echo Functionality** - Supports echoing received TLP packets, implementing communication disguise
4. **Multi-level Stealth Mode** - Implements three response modes (Normal/Camouflage/Deceptive) that automatically switch based on detected system behavior
5. **Adaptive Recovery Mechanism** - Automatically restores device state after long periods of inactivity, preventing permanent lockups
6. **Standard RW1C Registers** - Implements PCIe-compliant RW1C (Read-Write 1 to Clear) registers:
   - Supports correct "write 1 to clear" operations, handling PCIe status registers
   - Built-in multiple state (normal, warning, recovery, error) automatic handling mechanisms
   - Hardware event setting interface, allowing hardware to automatically set corresponding status bits
   - Access pattern monitoring functionality, ensuring device stable operation
7. **Interface Code Isolation** - Optimizes interface definitions between modules, increasing code isolation, enhancing security
8. **Abnormal Access Protection** - Detects and responds to non-standard register access patterns, protecting devices from being identified by security scanning tools
9. **ZeroWrite4K Enhancement** - Implements intelligent memory write filtering system:
   - Only writes to critical regions are actually stored
   - Non-critical region writes are ignored but return success
   - Supports critical region configuration and dynamic adjustment

## License Information

This project is open-sourced under the MIT License.

```
MIT License

Copyright (c) 2024 PCILeech Project Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## How to Contribute

We welcome community members to contribute to this project. If you wish to contribute, please follow these steps:

1. Fork this repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Contribution Guidelines

- Please ensure your code complies with the project's coding standards
- Add appropriate comments and documentation
- For FPGA design modifications, please provide corresponding simulation results or test reports
- Ensure your changes do not break existing functionality

## Contact Information

For any questions or suggestions, please contact us through:

- Submit an Issue
- Send an email to [1719297084@qq.com]

## Acknowledgements

- Special thanks to Ulf Frisk (pcileech@frizk.net) for the original PCILeech project
- Thanks to Dmytro Oleksiuk (@d_olex) for his contributions to the FIFO network module
- Thanks to all developers and researchers who have contributed to this project 