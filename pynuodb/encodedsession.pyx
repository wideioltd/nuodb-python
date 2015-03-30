# cython: profile=True
"""A module for housing the EncodedSession class.

Exported Classes:
EncodedSession -- Class for representing an encoded session with the database.
"""

from crypt import toByteString, fromByteString, toSignedByteString, fromSignedByteString
from crypt import ClientPassword, RC4Cipher

from exception import DataError, EndOfStream, ProgrammingError, db_error_handler, BatchError
from datatype import TypeObjectFromNuodb


import uuid
import struct
import protocol
import datatype
import decimal
import sys
import socket
import string
import struct
import threading
import sys
import xml.etree.ElementTree as ElementTree



from statement import Statement, PreparedStatement, ExecutionResult
from result_set import ResultSet


def checkForError(message):
    root = ElementTree.fromstring(message)
    if root.tag == "Error":
        raise SessionException(root.get("text"))


class SessionException(Exception):
    def __init__(self, value):
        self.__value = value
    def __str__(self):
        return repr(self.__value)


cdef class Session:
    __AUTH_REQ = "<Authorize TargetService=\"%s\" Type=\"SRP\"/>"
    __SRP_REQ = "<SRPRequest ClientKey=\"%s\" Cipher=\"RC4\" Username=\"%s\"/>"

    __SERVICE_REQ = "<Request Service=\"%s\"%s/>"
    __SERVICE_CONN = "<Connect Service=\"%s\"%s/>"

    cdef object __address
    cdef int __port
    cdef object __sock
    
    cdef object __cipherIn
    cdef object __cipherOut
    cdef object __service
    
    def __init__(self, host, port=None, service="Identity"):
        if not port:
            hostElements = host.split(":")
            if len(hostElements) == 2:
                host = hostElements[0]
                port = int(hostElements[1])
            else:
                port = 48004

        self.__address = host
        self.__port = port

        self.__sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.__sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.__sock.connect((host, port))

        self.__cipherOut = None
        self.__cipherIn = None

        self.__service = service

    @property
    def address(self):
        return self.__address

    @property
    def port(self):
        return self.__port

    # NOTE: This routine works only for agents ... see the sql module for a
    # still-in-progress example of opening an authorized engine session
    def authorize(self, account="domain", password=None):
        if not password:
            raise SessionException("A password is required for authorization")

        cp = ClientPassword()
        key = cp.genClientKey()

        self.send(Session.__AUTH_REQ % self.__service)
        response = self.__sendAndReceive(Session.__SRP_REQ % (key, account))

        root = ElementTree.fromstring(response)
        if root.tag != "SRPResponse":
            self.close()
            raise SessionException("Request for authorization was denied")

        salt = root.get("Salt")
        serverKey = root.get("ServerKey")
        sessionKey = cp.computeSessionKey(account, password, salt, serverKey)

        self._setCiphers(RC4Cipher(sessionKey), RC4Cipher(sessionKey))

        verifyMessage = self.recv()
        try:
            root = ElementTree.fromstring(verifyMessage)
        except Exception as e:
            self.close()
            raise SessionException("Failed to establish session with password: " + str(e)), None, sys.exc_info()[2]

        if root.tag != "PasswordVerify":
            self.close()
            raise SessionException("Unexpected verification response: " + root.tag)

        self.send(verifyMessage)

    def _setCiphers(self, cipherIn, cipherOut):
        self.__cipherIn = cipherIn
        self.__cipherOut = cipherOut

    # Issues the request, closes the session and returns the response string,
    # or raises an exeption if the session fails or the response is an error.
    def doRequest(self, attributes=None, text=None, children=None):
        requestStr = self.__constructServiceMessage(Session.__SERVICE_REQ, attributes, text, children)

        try:
            response = self.__sendAndReceive(requestStr)
            checkForError(response)

            return response
        finally:
            self.close()

    def doConnect(self, attributes=None, text=None, children=None):    
        connectStr = self.__constructServiceMessage(Session.__SERVICE_CONN, attributes, text, children)

        try:
            self.send(connectStr)
        except Exception:
            self.close()
            raise

    def __constructServiceMessage(self, template, attributes, text, children):
        attributeString = ""
        if attributes:
            for (key, value) in attributes.items():
                attributeString += " " + key + "=\"" + value + "\""

        message = template % (self.__service, attributeString)

        if children or text:
            root = ElementTree.fromstring(message)

            if text:
                root.text = text

            if children:
                for child in children:
                    root.append(child)

            message = ElementTree.tostring(root)

        return message

    def send(self, message):
        if not self.__sock:
            raise SessionException("Session is not open to send")

        if self.__cipherOut:
            message = self.__cipherOut.transform(message)

        lenStr = struct.pack("!I", len(message))

        try:
            self.__sock.send(lenStr + message)
        except Exception:
            self.close()
            raise

    def recv(self, doStrip=True):
        if not self.__sock:
            raise SessionException("Session is not open to receive")

        try:
            lengthHeader = self.__readFully(4)
            msgLength = int(struct.unpack("!I", lengthHeader)[0])
            
            msg = self.__readFully(msgLength)

        except Exception:
            self.close()
            raise

        if self.__cipherIn:
            if doStrip:
                msg = string.strip(self.__cipherIn.transform(msg))
            else:
                msg = self.__cipherIn.transform(msg)

        return msg


    def __readFully(self, msgLength):
        msg = ""
        
        while msgLength > 0:
            received = self.__sock.recv(msgLength)

            if not received:
                raise SessionException("Session was closed while receiving msgLength=[%d] len(msg)=[%d] "
                                       "len(received)=[%d]" % (msgLength, len(msg), len(received)))

            msg = msg + received
            msgLength = msgLength - len(received)

        return msg

    def close(self, force=False):
        if not self.__sock:
            return

        try:
            if force:
                self.__sock.shutdown(socket.SHUT_RDWR)

            if self.__sock:
                self.__sock.close()
        finally:
            self.__sock = None

    def __sendAndReceive(self, message):
        self.send(message)
        return self.recv()


class SessionMonitor(threading.Thread):

    def __init__(self, session, listener=None):
        threading.Thread.__init__(self)

        self.__session = session
        self.__listener = listener

    def run(self):
        while True:
            try:
                message = self.__session.recv()
            except:
                # the session was closed out from under us
                break

            try:
                root = ElementTree.fromstring(message)
            except:
                if self.__listener:
                    try:
                        self.__listener.invalid_message(message)
                    except:
                        pass
            else:
                if self.__listener:
                    try:
                        self.__listener.message_received(root)
                    except:
                        pass

        try:
            self.close()
        except:
            pass

    def close(self):
        if self.__listener:
            try:
                self.__listener.closed()
            except:
                pass
            self.__listener = None
        self.__session.close(force=True)


class BaseListener:

    def message_received(self, root):
        pass

    def invalid_message(self, message):
        pass

    def closed(self):
        pass

from libc.stdlib cimport malloc, free
from libc.string cimport strcat, strncat, memset, memchr, memcmp, memcpy, memmove        
        
cdef class EncodedSession(Session):

    """Class for representing an encoded session with the database.
    
    Public Functions:
    putMessageId -- Start a message with the messageId.
    putInt -- Appends an Integer value to the message.
    putScaledInt -- Appends a Scaled Integer value to the message.
    putString -- Appends a String to the message.
    putBoolean -- Appends a Boolean value to the message.
    putNull -- Appends a Null value to the message.
    putUUID -- Appends a UUID to the message.
    putOpaque -- Appends an Opaque data value to the message.
    putDouble -- Appends a Double to the message.
    putMsSinceEpoch -- Appends the MsSinceEpoch value to the message.
    putNsSinceEpoch -- Appends the NsSinceEpoch value to the message.
    putMsSinceMidnight -- Appends the MsSinceMidnight value to the message.
    putBlob -- Appends the Blob(Binary Large OBject) value to the message.
    putClob -- Appends the Clob(Character Large OBject) value to the message.
    putScaledTime -- Appends a Scaled Time value to the message.
    putScaledTimestamp -- Appends a Scaled Timestamp value to the message.    
    putScaledDate -- Appends a Scaled Date value to the message.
    putValue -- Determines the probable type of the value and calls the supporting function.
    getInt -- Read the next Integer value off the session.
    getScaledInt -- Read the next Scaled Integer value off the session.
    getString -- Read the next String off the session.
    getBoolean -- Read the next Boolean value off the session.
    getNull -- Read the next Null value off the session.
    getDouble -- Read the next Double off the session.
    getTime -- Read the next Time value off the session.
    getOpaque -- Read the next Opaque value off the session.
    getBlob -- Read the next Blob(Binary Large OBject) value off the session.
    getClob -- Read the next Clob(Character Large OBject) value off the session.
    getScaledTime -- Read the next Scaled Time value off the session.
    getScaledTimestamp -- Read the next Scaled Timestamp value off the session.
    getScaledDate -- Read the next Scaled Date value off the session.
    getUUID -- Read the next UUID value off the session.
    getValue -- Determine the datatype of the next value off the session, then call the
                supporting function.
    exchangeMessages -- Exchange the pending message for an optional response from the server.
    setCiphers -- Re-sets the incoming and outgoing ciphers for the session.
    
    Private Functions:
    __init__ -- Constructor for the EncodedSession class.
    _peekTypeCode -- Looks at the next Type Code off the session. (Does not move inpos)
    _getTypeCode -- Read the next Type Code off the session.
    _takeBytes -- Gets the next length of bytes off the session.
 
    """
    
    cdef object __input
    cdef int __inpos
    cdef char * __output 
    cdef int __outputsz
    cdef int __outputlen 
    
    cdef char *x__input
    cdef int x__inputsz
    cdef int x__inputlen 
    
    cdef int closed
    
    cpdef is_closed(self):
      return self.closed

    cpdef set_closed(self,v):
      self.closed=v
      
    def __init__(self, host, port, service='SQL2'):
        """Constructor for the EncodedSession class."""
        Session.__init__(self, host, port=port, service=service)        
        self.doConnect()
        self.__input=""
        self.__output = NULL
        self.__outputsz = 0
        self.__outputlen = 0
        self.x__input = NULL
        self.x__inputsz = 0
        self.x__inputlen = 0

        
        """ @type : str """
        self.__inpos = 0
        """ @type : int """
        self.closed = False

        
        
    # Mostly for connections
    def open_database(self, db_name, parameters, cp):
        """
        @type db_name str
        @type parameters dict[str,str]
        @type cp crypt.ClientPassword
        """
        self._putMessageId(protocol.OPENDATABASE).putInt(protocol.CURRENT_PROTOCOL_VERSION).putString(db_name).putInt(len(parameters))
        for (k, v) in parameters.iteritems():
            self.putString(k).putString(v)
        self.putNull().putString(cp.genClientKey())        
        self._exchangeMessages()
        version = self.getInt()
        serverKey = self.getString()
        salt = self.getString()

        return version, serverKey, salt

    def check_auth(self):
        try:
            self._putMessageId(protocol.AUTHENTICATION).putString(protocol.AUTH_TEST_STR)
            self._exchangeMessages()
        except SessionException as e:
            raise ProgrammingError('Failed to authenticate: ' + str(e)), None, sys.exc_info()[2]


    def get_autocommit(self):
        self._putMessageId(protocol.GETAUTOCOMMIT)
        self._exchangeMessages()
        val = self.getValue()

        return val

    def set_autocommit(self, value):
        self._putMessageId(protocol.SETAUTOCOMMIT).putInt(value)
        self._exchangeMessages(False)

    def send_close(self):

        self._putMessageId(protocol.CLOSE)
        self._exchangeMessages()

    def send_commit(self):
        self._putMessageId(protocol.COMMITTRANSACTION)
        self._exchangeMessages()
        val = self.getValue()
        return val

    def send_rollback(self):
        self._putMessageId(protocol.ROLLBACKTRANSACTION)
        self._exchangeMessages()

    def test_connection(self):
        # Create a statement handle
        self._putMessageId(protocol.CREATE)
        self._exchangeMessages()
        handle = self.getInt()

        # Use handle to query dual
        self._putMessageId(protocol.EXECUTEQUERY).putInt(handle).putString('select 1 as one from dual')
        self._exchangeMessages()

        rsHandle = self.getInt()
        count = self.getInt()
        colname = self.getString()
        result = self.getInt()
        fieldValue = self.getInt()
        r2 = self.getInt()

    # Mostly for cursors
    def create_statement(self):
        """
        @rtype: Statement
        """
        self._putMessageId(protocol.CREATE)
        self._exchangeMessages()
        return Statement(self.getInt())

    def execute_statement(self, statement, query):
        """
        @type statement Statement
        @type query str
        @rtype: ExecutionResult
        """
        self._putMessageId(protocol.EXECUTE).putInt(statement.handle).putString(query)
        self._exchangeMessages()

        result = self.getInt()
        rowcount = self.getInt()

        return ExecutionResult(statement, result, rowcount)

    def close_statement(self, statement):
        """
        @type statement Statement
        """
        self._putMessageId(protocol.CLOSESTATMENT).putInt(statement.handle)
        self._exchangeMessages(False)

    def create_prepared_statement(self, query):
        """
        @type query str
        @rtype: PreparedStatement
        """
        self._putMessageId(protocol.PREPARE).putString(query)
        self._exchangeMessages()

        handle = self.getInt()
        param_count = self.getInt()

        return PreparedStatement(handle, param_count)

    def execute_prepared_statement(self, prepared_statement, parameters):
        """
        @type prepared_statement PreparedStatement
        @type parameters list
        @rtype: ExecutionResult
        """
        self._putMessageId(protocol.EXECUTEPREPAREDSTATEMENT)
        self.putInt(prepared_statement.handle).putInt(len(parameters))
        for param in parameters:
            self.putValue(param)
        self._exchangeMessages()
        result = self.getInt()
        rowcount = self.getInt()
        r=ExecutionResult(prepared_statement, result, rowcount)
        return r

    def execute_batch_prepared_statement(self, prepared_statement, param_lists):
        """
        @type prepared_statement PreparedStatement
        @type param_lists list[list]

        """
        self._putMessageId(protocol.EXECUTEBATCHPREPAREDSTATEMENT)
        self.putInt(prepared_statement.handle)
        for parameters in param_lists:
            if prepared_statement.parameter_count != len(parameters):
                raise ProgrammingError("Incorrect number of parameters specified, expected %d, got %d" %
                                       (prepared_statement.parameter_count, len(parameters)))
            self.putInt(len(parameters))
            for param in parameters:
                self.putValue(param)
        self.putInt(-1)
        self.putInt(len(param_lists))
        self._exchangeMessages()

        results = []
        error_code = None
        error_string = None

        for _ in param_lists:
            result = self.getInt()
            results.append(result)
            if result == -3:
                ec = self.getInt()
                es = self.getString()
                # only report first
                if error_code is None:
                    error_code = ec
                    error_string = es

        if error_code is not None:
            raise BatchError(protocol.stringifyError[error_code] + ': ' + error_string, results)

        return results

    def fetch_result_set(self, statement):
        """
        @type statement Statement
        @rtype: ResultSet
        """
        self._putMessageId(protocol.GETRESULTSET).putInt(statement.handle)
        self._exchangeMessages()

        handle = self.getInt()
        colcount = self.getInt()

        col_num_iter = xrange(colcount)
        for _ in col_num_iter:
            self.getString()

        complete = False
        init_results = []
        next_row = self.getInt()

        while next_row == 1:
            row = [None] * colcount
            for i in col_num_iter:
                row[i] = self.getValue()

            init_results.append(tuple(row))

            try:
                next_row = self.getInt()
            except EndOfStream:
                break

        # the first chunk might be all of the data
        if next_row == 0:
            complete = True

        return ResultSet(handle, colcount, init_results, complete)

    def fetch_result_set_next(self, result_set):
        """
        @type result_set ResultSet
        """
        self._putMessageId(protocol.NEXT).putInt(result_set.handle)
        self._exchangeMessages()

        col_num_iter = xrange(result_set.col_count)

        result_set.clear_results()

        next_row = self.getInt()
        while next_row == 1:
            row = [None] * result_set.col_count
            for i in col_num_iter:
                row[i] = self.getValue()

            result_set.add_row(tuple(row))

            try:
                next_row = self.getInt()
            except EndOfStream:
                break

        if next_row == 0:
            result_set.complete = True

    def fetch_result_set_description(self, result_set):
        """
        @type result_set ResultSet
        @rtype: ResultSetMetadata
        """
        self._putMessageId(protocol.GETMETADATA).putInt(result_set.handle)
        self._exchangeMessages()

        description = [None] * self.getInt()
        for i in xrange(result_set.col_count):
            self.getString()    # catalog_name
            self.getString()    # schema_name
            self.getString()    # table_name
            column_name = self.getString()
            self.getString()    # column_label
            self.getValue()     # collation_sequence
            column_type_name = self.getString()
            self.getInt()       # column_type
            column_display_size = self.getInt()
            precision = self.getInt()
            scale = self.getInt()
            self.getInt()       # flags

            """TODO: type information should be derived from the type (column_type) not the
                     typename.  """
            description[i] = [column_name, TypeObjectFromNuodb(column_type_name),
                              column_display_size, None, precision, scale, None]

        return description

    #
    # Methods to put values into the next message

    def _putMessageId(self, messageId):
        """
        Start a message with the messageId.
        @type messageId int
        """
        self.__outputlen = 0
        self.putInt(messageId, isMessageId=True)
        return self

        
    cdef ensure_output_extend(self,int l):
      cdef char * oldoutput
      if (self.__outputlen+l>=self.__outputsz):        
         oldoutput=self.__output
         self.__outputsz=(self.__outputlen+l+1)*2
         self.__output=<char *> malloc(self.__outputsz)
         if oldoutput!=NULL:
           memcpy(self.__output,oldoutput,self.__outputlen)
           free(oldoutput)
      
    cdef output_append(self,char * buf, int len):    
           self.ensure_output_extend(len)
           memcpy(self.__output+self.__outputlen,buf,len)
           self.__outputlen+=len
    
           
    cdef ensure_input_extend(self,int l):
      cdef char * oldinput
      if (self.x__inputlen+l>=self.x__inputsz):        
         oldinput=self.x__input
         self.x__inputsz=(self.x__inputlen+l+1)*2
         self.x__input=<char *> malloc(self.x__inputsz)
         if oldinput!=NULL:
           memcpy(self.x__input,oldinput,self.x__inputlen)
           free(oldinput)
           
                   
    cpdef EncodedSession putInt(self, int value, int isMessageId=0):
        """
        Appends an Integer value to the message.
        @type value int
        @type isMessageId bool
        """
        if value < 32 and value > -11:
            self.ensure_output_extend(1)
            self.__output[self.__outputlen]=<char>(protocol.INT0 + value)
            self.__outputlen+=1
        else:
            self.ensure_output_extend(1)
            if isMessageId:
                valueStr = toByteString(value)
            else:
                valueStr = toSignedByteString(value)
            packed = chr(protocol.INTLEN1 - 1 + len(valueStr)) + valueStr            
            self.output_append( packed, len(packed))
        return self

    cdef EncodedSession putScaledInt(self, int value):
        """
        Appends a Scaled Integer value to the message.
        @type value decimal.Decimal
        """
        scale = abs(value.as_tuple()[2])
        valueStr = toSignedByteString(int(value * decimal.Decimal(10**scale)))
        packed = chr(protocol.SCALEDLEN0 + len(valueStr)) + chr(scale) + valueStr
        self.output_append(packed,len(packed))
        return self

    cpdef EncodedSession putString(self, str value):
        """
        Appends a String to the message.
        @type value str
        """
        length = len(value)
        if length < 40:
            packed = chr(protocol.UTF8LEN0 + length) + value
        else:
            lengthStr = toByteString(length)
            packed = chr(protocol.UTF8COUNT1 - 1 + len(lengthStr)) + lengthStr + value
        self.output_append(packed,len(packed))
        return self

    cpdef EncodedSession putBoolean(self, int value):
        """
        Appends a Boolean value to the message.
        @type value bool
        """
        if value!=0:
            self.__output[self.__outputlen] = protocol.TRUE
        else:
            self.__output[self.__outputlen] = protocol.FALSE
        self.__outputlen+=1            
        return self

    cpdef putNull(self):
        """Appends a Null value to the message."""
        s=chr(protocol.NULL)
        self.output_append(s,1)
        return self

    cpdef putUUID(self, value):
        """Appends a UUID to the message."""
        m= chr(protocol.UUID) + str(value)
        self.output_append(m,len(m))
        return self

    cpdef putOpaque(self, value):
        """Appends an Opaque data value to the message."""
        data = value.string
        length = len(data)
        if length < 40:
            packed = chr(protocol.OPAQUELEN0 + length) + data
        else:
            lengthStr = toByteString(length)
            packed = chr(protocol.OPAQUECOUNT1 - 1 + len(lengthStr)) + lengthStr + data
        self.output_append(packed,len(packed))
        return self

    def putDouble(self, value):
        """Appends a Double to the message."""
        valueStr = struct.pack('!d', value)
        packed = chr(protocol.DOUBLELEN0 + len(valueStr)) + valueStr
        self.output_append(packed,len(packed))
        return self

    def putMsSinceEpoch(self, value):
        """Appends the MsSinceEpoch value to the message."""
        valueStr = toSignedByteString(value)
        packed = chr(protocol.MILLISECLEN0 + len(valueStr)) + valueStr
        self.output_append(packed,len(packed))
        return self
        
    def putNsSinceEpoch(self, value):
        """Appends the NsSinceEpoch value to the message."""
        valueStr = toSignedByteString(value)
        packed = chr(protocol.NANOSECLEN0 + len(valueStr)) + valueStr
        self.output_append(packed,len(packed))
        return self
        
    def putMsSinceMidnight(self, value):
        """Appends the MsSinceMidnight value to the message."""
        valueStr = toByteString(value)
        packed = chr(protocol.TIMELEN0 + len(valueStr)) + valueStr
        self.output_append(packed,len(packed))
        return self

    # Not currently used by NuoDB
    def putBlob(self, value):
        """Appends the Blob(Binary Large OBject) value to the message."""
        data = value.string
        length = len(data)
        lengthStr = toByteString(length)
        lenlengthstr = len(lengthStr)
        packed = chr(protocol.BLOBLEN0 + lenlengthstr) + lengthStr + data
        self.output_append(packed,len(packed))
        return self

    def putClob(self, value):
        """Appends the Clob(Character Large OBject) value to the message."""
        length = len(value)
        lengthStr = toByteString(length)
        packed = chr(protocol.CLOBLEN0 + len(lengthStr)) + lengthStr + value
        self.output_append(packed,len(packed))
        return self
        
    def putScaledTime(self, value):
        """Appends a Scaled Time value to the message."""
        (ticks, scale) = datatype.TimeToTicks(value)
        valueStr = toByteString(ticks)
        if len(valueStr) == 0:
            packed = chr(protocol.SCALEDTIMELEN1) + chr(0) + chr(0)
        else:
            packed = chr(protocol.SCALEDTIMELEN1 - 1 + len(valueStr)) + chr(scale) + valueStr
        self.output_append(packed,len(packed))
        return self
    
    def putScaledTimestamp(self, value):
        """Appends a Scaled Timestamp value to the message."""
        (ticks, scale) = datatype.TimestampToTicks(value)
        valueStr = toSignedByteString(ticks)
        if len(valueStr) == 0:
            packed = chr(protocol.SCALEDTIMESTAMPLEN1) + chr(0) + chr(0)
        else:
            packed = chr(protocol.SCALEDTIMESTAMPLEN1 - 1 + len(valueStr)) + chr(scale) + valueStr
        self.output_append(packed,len(packed))
        return self
        
    def putScaledDate(self, value):
        """Appends a Scaled Date value to the message."""
        ticks = datatype.DateToTicks(value)
        valueStr = toSignedByteString(ticks)
        if len(valueStr) == 0:
            packed = chr(protocol.SCALEDDATELEN1) + chr(0) + chr(0)
        else:  
            packed = chr(protocol.SCALEDDATELEN1 - 1 + len(valueStr)) + chr(0) + valueStr
        self.output_append(packed,len(packed))
        return self

    def putValue(self, value):
        """Determines the probable type of the value and calls the supporting function."""
        if value == None:
            return self.putNull()
        elif type(value) == int:
            return self.putInt(value)
        elif type(value) == float:
            return self.putDouble(value)
        elif isinstance(value, decimal.Decimal):
            return self.putScaledInt(value)
        elif isinstance(value, datatype.Timestamp): #Note: Timestamp must be above Date because it inherits from Date
            return self.putScaledTimestamp(value)
        elif isinstance(value, datatype.Date):
            return self.putScaledDate(value)
        elif isinstance(value, datatype.Time):
            return self.putScaledTime(value)
        elif isinstance(value, datatype.Binary):
            return self.putOpaque(value)
        elif value is True or value is False:            
            return self.putBoolean(1 if value else 0)
        else:
            return self.putString(str(value))
        
    #
    # Methods to get values out of the last exchange

    def getInt(self):
        """Read the next Integer value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.INTMINUS10, protocol.INT31 + 1):
            return typeCode - 20

        elif typeCode in range(protocol.INTLEN1, protocol.INTLEN8 + 1):
            return fromSignedByteString(self._takeBytes(typeCode - 51))

        raise DataError('Not an integer')

    def getScaledInt(self):
        """Read the next Scaled Integer value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.SCALEDLEN0, protocol.SCALEDLEN8 + 1):
            scale = fromByteString(self._takeBytes(1))
            value = fromSignedByteString(self._takeBytes(typeCode - 60))
            return decimal.Decimal(value) / decimal.Decimal(10**scale)

        raise DataError('Not a scaled integer')

    def getString(self):
        """Read the next String off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.UTF8LEN0, protocol.UTF8LEN39 + 1):
            return self._takeBytes(typeCode - 109)

        if typeCode in range(protocol.UTF8COUNT1, protocol.UTF8COUNT4 + 1):
            strLength = fromByteString(self._takeBytes(typeCode - 68))
            return self._takeBytes(strLength)

        raise DataError('Not a string')

    def getBoolean(self):
        """Read the next Boolean value off the session."""
        typeCode = self._getTypeCode()

        if typeCode == protocol.TRUE:
            return True
        if typeCode == protocol.FALSE:
            return False

        raise DataError('Not a boolean')

    def getNull(self):
        """Read the next Null value off the session."""
        if self._getTypeCode() != protocol.NULL:
            raise DataError('Not null')

    def getDouble(self):
        """Read the next Double off the session."""
        typeCode = self._getTypeCode()
        
        if typeCode == protocol.DOUBLELEN0:
            return 0.0
        
        if typeCode in range(protocol.DOUBLELEN0 + 1, protocol.DOUBLELEN8 + 1):
            test = self._takeBytes(typeCode - 77)
            if typeCode < protocol.DOUBLELEN8:
                for i in xrange(0, protocol.DOUBLELEN8 - typeCode):
                    test = test + chr(0)
            return struct.unpack('!d', test)[0]
            
        raise DataError('Not a double')

    def getTime(self):
        """Read the next Time value off the session."""
        typeCode = self._getTypeCode()
        
        if typeCode in range(protocol.MILLISECLEN0, protocol.MILLISECLEN8 + 1):
            return fromSignedByteString(self._takeBytes(typeCode - 86))
            
        if typeCode in range(protocol.NANOSECLEN0, protocol.NANOSECLEN8 + 1):
            return fromSignedByteString(self._takeBytes(typeCode - 95))
            
        if typeCode in range(protocol.TIMELEN0, protocol.TIMELEN4 + 1):
            return fromByteString(self._takeBytes(typeCode - 104))
            
        raise DataError('Not a time')
    
    def getOpaque(self):
        """Read the next Opaque value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.OPAQUELEN0, protocol.OPAQUELEN39 + 1):
            return datatype.Binary(self._takeBytes(typeCode - 149))

        if typeCode in range(protocol.OPAQUECOUNT1, protocol.OPAQUECOUNT4 + 1):
            strLength = fromByteString(self._takeBytes(typeCode - 72))
            return datatype.Binary(self._takeBytes(strLength))

        raise DataError('Not an opaque value')

    # Not currently used by NuoDB
    def getBlob(self):
        """Read the next Blob(Binary Large OBject) value off the session."""
        typeCode = self._getTypeCode()
        
        if typeCode in range(protocol.BLOBLEN0, protocol.BLOBLEN4 + 1):
            strLength = fromByteString(self._takeBytes(typeCode - 189))
            return datatype.Binary(self._takeBytes(strLength))

        raise DataError('Not a blob')
    
    def getClob(self):
        """Read the next Clob(Character Large OBject) value off the session."""
        typeCode = self._getTypeCode()
        
        if typeCode in range(protocol.CLOBLEN0, protocol.CLOBLEN4 + 1):
            strLength = fromByteString(self._takeBytes(typeCode - 194))
            return self._takeBytes(strLength)

        raise DataError('Not a clob')
    
    def getScaledTime(self):
        """Read the next Scaled Time value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.SCALEDTIMELEN1, protocol.SCALEDTIMELEN8 + 1):
            scale = fromByteString(self._takeBytes(1))
            time = fromByteString(self._takeBytes(typeCode - 208))
            ticks = decimal.Decimal(str(time)) / decimal.Decimal(10**scale)
            return datatype.TimeFromTicks(round(int(ticks)), int((ticks % 1) * decimal.Decimal(1000000)))

        raise DataError('Not a scaled time')
    
    def getScaledTimestamp(self):
        """Read the next Scaled Timestamp value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.SCALEDTIMESTAMPLEN1, protocol.SCALEDTIMESTAMPLEN8 + 1):
            scale = fromByteString(self._takeBytes(1))
            timestamp = fromSignedByteString(self._takeBytes(typeCode - 216))
            ticks = decimal.Decimal(str(timestamp)) / decimal.Decimal(10**scale)
            return datatype.TimestampFromTicks(round(int(ticks)), int((ticks % 1) * decimal.Decimal(1000000)))

        raise DataError('Not a scaled timestamp')
    
    def getScaledDate(self):
        """Read the next Scaled Date value off the session."""
        typeCode = self._getTypeCode()

        if typeCode in range(protocol.SCALEDDATELEN1, protocol.SCALEDDATELEN8 + 1):
            scale = fromByteString(self._takeBytes(1))
            date = fromSignedByteString(self._takeBytes(typeCode - 200))
            return datatype.DateFromTicks(round(date/10.0**scale))

        raise DataError('Not a scaled date')

    def getUUID(self):
        """Read the next UUID value off the session."""
        if self._getTypeCode() == protocol.UUID:
            return uuid.UUID(bytes=self._takeBytes(16))
        if self._getTypeCode() == protocol.SCALEDCOUNT1:
            # before version 11
            pass
        if self._getTypeCode() == protocol.SCALEDCOUNT2:
            # version 11 and later
            pass

        raise DataError('Not a UUID')

    def getValue(self):
        """Determine the datatype of the next value off the session, then call the
        supporting function.
        """
        typeCode = self._peekTypeCode()
        
        # get null type
        if typeCode is protocol.NULL:
            return self.getNull()
        
        # get boolean type
        elif typeCode in [protocol.TRUE, protocol.FALSE]:
            return self.getBoolean()
        
        # get uuid type
        elif typeCode in [protocol.UUID, protocol.SCALEDCOUNT1, protocol.SCALEDCOUNT2]:
            return self.getUUID()
        
        # get integer type
        elif typeCode in range(protocol.INTMINUS10, protocol.INTLEN8 + 1):
            return self.getInt()
        
        # get scaled int type
        elif typeCode in range(protocol.SCALEDLEN0, protocol.SCALEDLEN8 + 1):
            return self.getScaledInt()
        
        # get double precision type
        elif typeCode in range(protocol.DOUBLELEN0, protocol.DOUBLELEN8 + 1):
            return self.getDouble()
        
        # get string type
        elif typeCode in range(protocol.UTF8COUNT1, protocol.UTF8COUNT4 + 1) or \
             typeCode in range(protocol.UTF8LEN0, protocol.UTF8LEN39 + 1):
            return self.getString()
        
        # get opaque type
        elif typeCode in range(protocol.OPAQUECOUNT1, protocol.OPAQUECOUNT4 + 1) or \
             typeCode in range(protocol.OPAQUELEN0, protocol.OPAQUELEN39 + 1):
            return self.getOpaque()
        
        # get blob/clob type
        elif typeCode in range(protocol.BLOBLEN0, protocol.CLOBLEN4 + 1):
            return self.getBlob()
        
        # get time type
        elif typeCode in range(protocol.MILLISECLEN0, protocol.TIMELEN4 + 1):
            return self.getTime()
        
        # get scaled time
        elif typeCode in range(protocol.SCALEDTIMELEN1, protocol.SCALEDTIMELEN8 + 1):
            return self.getScaledTime()
        
        # get scaled timestamp
        elif typeCode in range(protocol.SCALEDTIMESTAMPLEN1, protocol.SCALEDTIMESTAMPLEN8 + 1):
            return self.getScaledTimestamp()
        
        # get scaled date
        elif typeCode in range(protocol.SCALEDDATELEN1, protocol.SCALEDDATELEN8 + 1):
            return self.getScaledDate()
        
        else:
            raise NotImplementedError("typecode not implemented")

    def _exchangeMessages(self, getResponse=True):
        """Exchange the pending message for an optional response from the server."""
        try:
            self.send(self.__output[:self.__outputlen])
        finally:
            self.__outputlen=0

        if getResponse is True:
            self.__input = self.recv(False)
            self.x__input=self.__input
            self.__inpos = 0
            
            error = self.getInt()

            if error != 0:
                db_error_handler(error, self.getString())
        else:
            self.__input = None
            self.__inpos = 0

    def setCiphers(self, cipherIn, cipherOut):
        """Re-sets the incoming and outgoing ciphers for the session."""
        Session._setCiphers(self, cipherIn, cipherOut)

    # Protected utility routines

    cdef int _peekTypeCode(self):
        """Looks at the next Type Code off the session. (Does not move inpos)"""
        #return <int>(self.__input[self.__inpos])
        return ord(self.__input[self.__inpos])

    def _getTypeCode(self):
        """Read the next Type Code off the session."""
        if self.__inpos >= len(self.__input):
            raise EndOfStream('end of stream reached')
            
        try:
            return ord(self.__input[self.__inpos])
        finally:
            self.__inpos += 1

    def _takeBytes(self, length):
        """Gets the next length of bytes off the session."""
        if self.__inpos + length > len(self.__input):
            raise EndOfStream('end of stream reached')
                        
        try:
            return self.__input[self.__inpos:self.__inpos + length]
        finally:
            self.__inpos += length
