=begin
TmnxPortID decoding based on information in TIMETRA-TC-MIB.
type_code = (x & int('11100000000000000000000000000000', 2)) >> 29

A portid is an unique 32 bit number encoded as shown below.

    32 30 | 29 26 | 25 22 | 21 16 | 15  1 |
    +-----+-------+-------+-------+-------+
    |000  |  slot |  mda  | port  |  zero | Physical Port
    +-----+-------+-------+-------+-------+

    32 30 | 29 26 | 25 22 | 21 16 | 15  1 |
    +-----+-------+-------+-------+-------+
    |001  |  slot |  mda  | port  |channel| Channel
    +-----+-------+-------+-------+-------+

Slots, mdas (if present), ports, and channels are numbered
starting with 1.

    32     29 | 28             10 | 9   1 |
    +---------+-------------------+-------+
    | 0 1 0 0 |   zeros           |   ID  | Virtual Port
    +---------+-------------------+-------+

    32     29 | 28                9 | 8 1 |
    +---------+---------------------+-----+
    | 0 1 0 1 |   zeros             | ID  | LAG Port
    +---------+---------------------+-----+

A card port number (cpn) has significance within the context
of the card on which it resides(ie., cpn 2 may exist in one or
more cards in the chassis).  Whereas, portid is an
unique/absolute port number (apn) within a given chassis.

An 'invalid portid' is a TmnxPortID with a value of 0x1e000000 as
represented below.

    32 30 | 29 26 | 25 22 | 21 16 | 15  1 |
    +-----+-------+-------+-------+-------+
    |zero | ones  | zero  |  zero |  zero | Invalid Port
    +-----+-------+-------+-------+-------+"

The oidIndex for items in TIMETRA-SAP-MIB::sapBaseInfoTable are structured
as follows:  svcIf.sapPortId.sapEncapValue

sapBaseInfoEntry                 OBJECT-TYPE
SYNTAX      SapBaseInfoEntry
MAX-ACCESS  not-accessible
STATUS      current
DESCRIPTION "Information about a specific SAP."
INDEX       {svcId, sapPortId, sapEncapValue }

Note that the Nokias introduced something called a BreakoutConnection
port which deviates from the latest TIMETRA-TC-MIB and TIMETRA-PORT-MIB.
The ID follows a similar structure to "Scheme B" from the related
TIMETRA-CHASSIS-MIB but deviates in the last 14 bits. The port names take
the form of SLOT/MDA/cX/Y (where c is the character 'c' and X and Y are
derived from last 14 bits). On comparing the bit structure to known ports
of this type, the bit structure was determined to be as follows:

    |32 30| 29 24 | 23 19 | 18 15 | 14  13 | 12 7 | 6  1 |
    +-----+-------+-------+-------+--------+------+------+
    |011  |  zero |  slot |  mda  |  10    | X    | Y    |
    +-----+-------+-------+-------+--------+------+------+
=end

class TmnxPortId
    ##
    # Note that we use class variables and methods to keep things scoped
    # but to limit the need to instantiate an object everytime logstash 
    # filter is called.
    ##
    @@INVALID = 0x1e000000
    @@TYPE_MASK = 0xe0000000
    @@TYPE_SHIFT = 29
    @@SLOT_MASK = 0x1e000000
    @@SLOT_SHIFT = 25
    @@MDA_MASK = 0x1e00000
    @@MDA_SHIFT = 21
    @@PORT_MASK = 0x1f8000
    @@PORT_SHIFT = 15
    @@CHANNEL_MASK = 0x7fff
    @@VIRTUALPORT_MASK = 0x1ff
    @@LAG_MASK = 0xff
    @@CHANNEL_VIRTUALPORT_MASK = 0x10000000
    @@CHANNEL_VIRTUALPORT_SHIFT = 28
    @@VIRTUAL_PREFIX = 0b0100 << @@CHANNEL_VIRTUALPORT_SHIFT
    @@LAG_PREFIX = 0b0101 << @@CHANNEL_VIRTUALPORT_SHIFT

    @@PHYSICAL_PORT_TYPE = 0b000
    @@CHANNEL_PORT_TYPE = 0b001
    @@VIRT_PORT_OR_LAG_TYPE = 0b010
    @@BREAKOUT_CONN_TYPE = 0b011

    def self.decode(port_id)
        #make sure we have an int
        port_id = port_id.to_i
        port_type = (port_id & @@TYPE_MASK) >> @@TYPE_SHIFT
        slot = (port_id & @@SLOT_MASK) >> @@SLOT_SHIFT
        mda = (port_id & @@MDA_MASK) >> @@MDA_SHIFT
        port = (port_id & @@PORT_MASK) >> @@PORT_SHIFT

        #check for the special invalid port id as defined by spec
        if(port_id == @@INVALID) then
            return
        end

        #Based on type, parse the id or return nil if unrecognized
        if port_type == @@BREAKOUT_CONN_TYPE then
            brslot = (port_id & 0x7c0000 ) >> 18
            brmda = (port_id & 0x3c000 ) >> 14
            brc = (port_id & 0xfc0 ) >> 6
            brlast = (port_id & 0x3f )
            return "#{brslot}/#{brmda}/c#{brc}/#{brlast}"
        elsif port_type == @@PHYSICAL_PORT_TYPE then
            return "#{slot}/#{mda}/#{port}"
        elsif port_type == @@CHANNEL_PORT_TYPE then
            channel = port_id & @@CHANNEL_MASK
            return "#{slot}/#{mda}/#{port}.#{channel}"
        elsif port_type == @@VIRT_PORT_OR_LAG_TYPE then
            channel_virtual_port = (port_id & @@CHANNEL_VIRTUALPORT_MASK) >> @@CHANNEL_VIRTUALPORT_SHIFT
            if channel_virtual_port == 0 then
                virtual_port = port_id & @@VIRTUALPORT_MASK
                return "virtual-#{virtual_port}"
            elsif channel_virtual_port == 1 then
                lag = port_id & @@LAG_MASK
                return "lag-#{lag}"
            end
        end

        return
    end
    
    ##
    #parse id in format prefix.portid.suffix and convert to 
    # prefix-name-suffix
    def self.decode_sap(sap_id)
        #verify it is a valid id
        if sap_id.nil? then
            return
        end
        id_parts = sap_id.split('.')
        if id_parts.length() != 3 then
            return
        end

        #get portname
        port_name = decode(id_parts[1])
        if port_name.nil? then
            return
        end

        #return formatted id
        return "#{id_parts[0]}-#{port_name}-#{id_parts[2]}"
    end
end

