-- variables
wificfg={}
STATUS_REGISTER=0
HTTP_REGISTER=0
SSID_REGISTER=0
GOT_IP_FLAG=3
SSID_RECEIVED_FLAG=4
WIFIPASSWORD_RECEIVED_FLAG=5
CIK_RECEIVED_FLAG=6
HTTP_CONNECTED_FLAG=7
UART_TERMINATOR1='\n'
UART_TERMINATORS='[\r\n]'
CON_LEN_HDR = "Content-Length: <CONLEN>\r\n\r\n"

-- update status register periodicaly
tmr.alarm(1, 333, 1, function()
    STATUS_REGISTER=wifi.sta.status()
    STATUS_REGISTER=bit.bor(STATUS_REGISTER,HTTP_REGISTER,SSID_REGISTER)
end)

send_data = function(BODY)
    HTTP_WR_HDR = "POST /onep:v1/stack/alias HTTP/1.1\r\nHost: m2.exosite.com\r\nX-Exosite-CIK: " .. CIK .. "\r\nContent-Type: application/x-www-form-urlencoded; charset=utf-8\r\nContent-Length: <CONLEN>\r\n\r\n"
    CONLEN = string.len(BODY)
    HTTP_WR_HDR = string.gsub(HTTP_WR_HDR,"<CONLEN>",CONLEN)
    REQ = HTTP_WR_HDR .. BODY
    push_request(REQ)
end

read_data = function(dataz)
    HTTP_RD_HDR = "GET /onep:v1/stack/alias?" .. dataz .. " HTTP/1.1\r\nHost: m2.exosite.com\r\nX-Exosite-CIK: " .. CIK .. "\r\nAccept: application/x-www-form-urlencoded; charset=utf-8\r\n\r\n"
    REQ = HTTP_RD_HDR
    push_request(REQ)
end

push_request = function(dataz)
    -- if connected then send request to server
    if bit.isset(HTTP_REGISTER,HTTP_CONNECTED_FLAG) then
        hs:send(dataz)
    -- else connect and then send, also handle events
    else
        hs = net.createConnection(net.TCP, 0)
        hs:on("connection", function (skt)
            HTTP_REGISTER=bit.set(HTTP_REGISTER,HTTP_CONNECTED_FLAG)
            -- this is dangerous async stuff
            hs:send(dataz)
        end)
        hs:on("disconnection", function (skt)
            HTTP_REGISTER=bit.clear(HTTP_REGISTER,HTTP_CONNECTED_FLAG)
        end)
        hs:on("receive", function (skt, RESP)
            -- TODO: handle HTTP response body properly
            httpcode = string.sub(RESP,10,12)
            a,b = string.find(RESP,"\r\n\r\n")
            resplen = string.len(RESP)
            uartresp = string.sub(RESP,b+1,resplen)
            uart.write(0, httpcode .. UART_TERMINATOR1)
            if string.len(uartresp) > 2 then
                uart.write(0, uartresp .. UART_TERMINATOR1)
            end
        end)
        hs:connect(80, 'm2.exosite.com')
    end
end

-- initialise custom UART handler
-- be careful as this steals LUA interpreter
uart.on("data", UART_TERMINATOR1, function(data)
    uart.write(0, STATUS_REGISTER)
    local s = string.gsub(data, UART_TERMINATORS, "") -- remove termination characters
    local slen = string.len(s)
    local b = string.byte(s,1)
    local c = string.sub(s,1,1)
    if s == 'uartstop' then
        -- return to lua interpreter
        uart.on('data')
        -- close connection
        if bit.isset(HTTP_REGISTER, HTTP_CONNECTED_FLAG) then
            hs:close()
        end
    elseif b == 0xf0 then
        -- dont pass to HTTP
    elseif b == 0xf3 then
        -- disconnect from HTTP and restart
        uart.on('data')
        if bit.isset(HTTP_REGISTER, HTTP_CONNECTED_FLAG) then
            hs:close()
        end
        node.restart()
    -- read and store SSID
    elseif bit.isclear(SSID_REGISTER, SSID_RECEIVED_FLAG) then
        wificfg.ssid=s
        SSID_REGISTER=bit.set(SSID_REGISTER, SSID_RECEIVED_FLAG)
    -- read and store WIFI passphrase, connect to AP
    elseif bit.isclear(SSID_REGISTER, WIFIPASSWORD_RECEIVED_FLAG) then
        wificfg.pwd=s
        SSID_REGISTER=bit.set(SSID_REGISTER, WIFIPASSWORD_RECEIVED_FLAG)
        wifi.sta.config(wificfg.ssid, wificfg.pwd)
        wifi.sta.autoconnect(1)
        tmr.alarm(3, 200, 1, function()
            if wifi.sta.getip()== nil then
            else
                tmr.stop(3)
                SSID_REGISTER=bit.set(SSID_REGISTER, GOT_IP_FLAG)
            end
        end)
    elseif bit.isclear(HTTP_REGISTER, CIK_RECEIVED_FLAG) then
        -- do this once
        CIK=s
        HTTP_REGISTER=bit.set(HTTP_REGISTER, CIK_RECEIVED_FLAG)
    elseif c == 'W' and slen > 3 then
        dataz=string.sub(s,2,slen)
        send_data(dataz .. "\r\n")
    elseif c == 'R' and slen > 1 then
        dataz=string.sub(s,2,slen)
        read_data(dataz)
    else
        uart.write(0,'undefined error')
    end
end, 0)
