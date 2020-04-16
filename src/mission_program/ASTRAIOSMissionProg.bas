'----------------------------------------------------------------------
' ASTRAIOS & Flight and Space Class 2020
' Written by Dan Ruder, 4/21/2015 - 5/28/2019
' Modified by Yiyang (Ian) Wang, 3/16-3/21
'
' Reads a temperature sensor on B.1 input, a humdity sensor on B.2 every 1  
' second, and UW sensor on B.3 writes to 32K EEPROM.
'
' Example satellite mission program
'
' Mission specification
' ---------------------
'
' 1. The mission will last approximately 120 minutes; 90 up and 30 down; 
'    this could be shorter or longer depending on when the balloon pops.
'
' 2. The mission program runs as a loop that performs these activities:
'
'    a. Collect sensor data and store it into an EEPROM so that it
'       can be retrieved after the flight.  The frequency for reading
'       sensors is dependent on the number of sensors and the size
'       of the EEPROM.  This program assumes the satellite will have
'       a 32K EEPROM and three sensors.  Thus:
'
'          32786 bytes / 3 = 10,922 readings per sensor
'          10,922 readings / 120 minutes = ~ 91 readings/minute
'
'       So it would be logical to read once per second:
'
'          10,922 / 60 = ~182 minutes of flight time
'
'       If you use a different number of sensors or size EEPROM, you
'       will need to adjust these numbers.
'
'
'    The timing of these activities depends on the science questions
'    you are trying to answer by conducting the mission.
'
'
' Implementation Notes
' --------------------
' 
' This program is designed for flight controllers with the following
' components: PICAXE 14M2., 32K EEPROM on I2C bus, four analog sensors,
' a digital camera connector, and a serial I/O connector.
'
' This program has the following structure:

' a. Initialize hardware
'
' b. Wait for the user to remove the mission start pin. This pin has
'    two purposes:  to wait until just before the flight begins before
'    collecting data, and to enable retrieving collected mission data
'    the flight has finished.  When the pin is inserted, the program
'    will read the contents of the EEPROM and write it to the serial
'    port.
'    
' c. Enter the main loop that reads sensors, writes data to EEPROM,
'    and takes pictures.  Since there are four sensors, this program
'    stores data in the EEPROM using the following pattern:
'
'
'      +-----------------------------------------------------+
'      | S1| S2| S3| S1| S2| S3| S1| S2| --> | S1| S2| S3| S1|
'      +-----------------------------------------------------+
'        0   1   2   3   4   5   6   7   ...            32767
'
' d. Stop recording sensor data when all memory is filled up, but 
'    let the camera continue to operate because flight may have 
'    lasted longer than expected.   - using GOPRO not used anymore!
'
' This program cannot use PICAXE parallel tasks or the time special
' function register because these features use the same timer as the
' I2C bus and conflict with each other.
'
' Finally, there are comments throughout the code explaining the what
' the code is supposed to do and why.  The code itself explains how.
'
' Good luck!
'----------------------------------------------------------------------


#picaxe 14m2


'-------------------------------------------------------------
' Variables - make sure the b variables don't overlap the w variables
'-------------------------------------------------------------
symbol humidity_reading = b0 ' variables to hold sensor readings for logging
symbol temp_reading     = b1 
symbol uv_reading       = b2


symbol i         = w2  ' index for reading from/writing to EEPROM
symbol n         = w3  ' loop counter
symbol t1        = w4  ' temporary variable
symbol loopTime  = w5  ' used to improve accuracy of main loop's runtime (units = milliseconds)



'-------------------------------------------------------------
' Sensor names -- verify that you connect the right sensor to the right pin
' change these if you connect sensors to different pins
'-------------------------------------------------------------

'fixed bug 4_15:740PM switched HUM and T around'
symbol HUMIDITY_SEN  = B.1
symbol TEMP_SEN      = B.2
symbol UV_SEN        = B.5

symbol START_PIN_VAL = pinC.3  ' Use this form to read the start pin


'-------------------------------------------------------------
' EEPROM Memory constants
'-------------------------------------------------------------
symbol EEPROM_ADDRESS     = %10100000   ' Address of EEPROM on I2C bus
symbol MEMORY_SIZE        = 32768       ' Size of EEPROM memory in number of bytes


'-------------------------------------------------------------
' Timing constants - all units are millisconds
'-------------------------------------------------------------
symbol HARDWARE_WARMUP_DELAY = 30000    ' Wait for hardware to power own and settle to operating steady state
symbol EEPROM_WRITE_DELAY    = 7        ' Wait after each EEPROM write to give EEPROM time to finish
symbol SENSOR_INTERVAL       = 1000     ' Read sensor every 1 second; main loop runs at this speed



'-------------------------------------------------------------
' MISSION BEGINS RUNNING HERE!
'-------------------------------------------------------------
' After power on, let hardware settle by giving all devices a 
' little time to operate at normal voltage. Then initialize 
' I2C bus so we can use the external 32K EEPROM
'-------------------------------------------------------------

pause HARDWARE_WARMUP_DELAY
gosub InitI2C   


'-------------------------------------------------------------
' Wait for user to remove the mission start pin to begin the
' flight's mission program.  This pin acts as a switch
' (0 = inserted, 1 = removed) to either run the mission program 
' or upload the mission data to a PC.
'
' After you recover the satellite, insert the start pin before 
' powering it up and keep the start pin inserted.  Then connect 
' the satellite to PC to to upload the mission data.
'-------------------------------------------------------------

do
   sertxd ("Waiting for start pin to be removed",13,10)
   gosub UploadData
   'START_PIN_VAL = 1 test
loop while START_PIN_VAL = 0
		

'-------------------------------------------------------------
' Mission program begins here
'-------------------------------------------------------------

let i = 0   ' address for EEPROM memory writes
 
do
   loopTime = SENSOR_INTERVAL

   '-------------------------------------------------------------
   ' Read sensors and put them into EEPROM memory.  Stop when the
   ' memory is full
   '-------------------------------------------------------------
   if i < MEMORY_SIZE then
	   
	readadc HUMIDITY_SEN, humidity_reading   
      readadc TEMP_SEN,     temp_reading	
	readadc UV_SEN, uv_reading

      gosub WriteEEPROM
      i = i + 3

      sertxd ("H= ",#humidity_reading, " T= ", #temp_reading, " UV= ", #UV_reading, 13,10)  ' output reading for easy testing

      ' Compensate for time spent writing to EEPROM since it was long
      loopTime = loopTime - EEPROM_WRITE_DELAY
   end if 
     
   '-------------------------------------------------------------
   ' Wait until the next time to read the sensors
   '-------------------------------------------------------------
   pause loopTime

loop

gosub StopI2C

end



'-------------------------------------------------------------
' Upload the flight data from the EEPROM to the PC using CSV
' (comma-separated value) format to make the data easy to analyze
' in Excel.
'
' Print header followed by all data values followed by footer.
'
' NOTE: THE HEADER MUST MATCH PATTERN THAT WAS USED TO WRITE DATA
' INTO EEPROM SO THAT WE KNOW WHICH DATA CAME FROM WHICH SENSOR
'
' Note:  the PICAXE transmits data over the serial port at a
' maximum of 4800 baud (600 chars/second), and we are writing 
' 23 chars 8192 times (188,416 total), which would give a predicted
' runtime of about 5:14 minutes.  However, the EEPROM and the 
' PICAXE also need their time to read, so the measured runtime
' was actually 12 minutes (effective rate 2100 baud).
'
' Since we call this in the loop waiting for the START PIN, we
' likely don't want to wait a full 12 minutes from the time we
' pull the START PIN until we release the balloons, so we will
' check the START PIN HERE EVERY 256 times through the loop
' (256 is a power to 2 and an even divisor of 32768; when the 
' START PIN is removed, return early so the calling START PIN
' checking loop can exit early and begin the mission. 
'
' This means START PIN must remain inserted while downloading
' mission data.
'-------------------------------------------------------------
UploadData:

   sertxd ("Reading,Humidity, Temperature, UV", 13,10)
	
   let i  = 0
   let n  = 1
   let t1 = 0
	
   do
      gosub ReadEEPROM
      i = i + 3
      sertxd (#n, ",", #humidity_reading, ",", #temp_reading, ",", #uv_Reading, 13,10)
      
      
      ' Periodically check the START PIN and return early if it has
      ' been removed so we can start the mission.
      t1 = n % 256

      if t1 = 0 and START_PIN_VAL = 1 then
         return
      end if
      
      n = n + 1

   loop while i < MEMORY_SIZE
	
   sertxd ("END,END,END", 13,10)
   
return



'---------------------------------------------------------
'Arguments: EEPROM_ADDRESS
'---------------------------------------------------------
InitI2C:
   hi2csetup I2CMASTER, EEPROM_ADDRESS, i2cfast, i2cword
return


'---------------------------------------------------------
' Arguments:  None
'---------------------------------------------------------	
StopI2C:
   hi2csetup OFF
return


'---------------------------------------------------------
' Arguments:  i, humidity_reading, temp_reading, uv_reading
'---------------------------------------------------------
WriteEEPROM:
   hi2cout i, (humidity_reading, temp_reading, uv_reading)	
   pause EEPROM_WRITE_DELAY  ' Give EEPROM time to finish the write
return


'---------------------------------------------------------
' Arguments:  i, humidity_reading,temp_reading, uv_reading
'---------------------------------------------------------
ReadEEPROM:
	hi2cin i, (humidity_reading, temp_reading, uv_reading)
return

