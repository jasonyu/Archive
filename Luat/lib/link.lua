--- 数据链路激活(创建、连接、状态维护)
-- @module link
-- @author 稀饭放姜、小强
-- @license MIT
-- @copyright openLuat.com
-- @release 2017.9.20

module(..., package.seeall)
local publish = sys.publish
local request = ril.request
local ready = false

function isReady() return ready end

-- apn，用户名，密码
local apnname, username, password

function setAPN(apn, user, pwd)
    apnname, username, password = apn, user, pwd
end

-- SIM卡 IMSI READY以后自动设置APN
sys.subscribe("IMSI_READY", function()
    if not apnname then -- 如果未设置APN设置默认APN
        local mcc, mnc = tonumber(sim.getMcc(), 16), tonumber(sim.getMnc(), 16)
        apnname, username, password = apn and apn.get_default_apn(mcc, mnc) -- 如果存在APN库自动获取运营商的APN
        if not apnname or apnname == '' then -- 默认情况，如果联通卡设置为联通APN 其他都默认为CMNET
            apnname = (mcc == 0x460 and (mnc == 0x01 or mnc == 0x06)) and 'UNINET' or 'CMNET'
        end
    end
    username = username or ''
    password = password or ''
end)

local function queryStatus() request("AT+CIPSTATUS") end

ril.regrsp('+CGATT', function(a, b, c, intermediate)
    if intermediate == "+CGATT: 1" then
        request("AT+CIPSTATUS")
    elseif net.getState() == 'REGISTERED' then
        sys.timer_start(request, 2000, "AT+CGATT?")
    end
end)
ril.regrsp('+CIPSHUT', function(cmd, success)
    if success then
        ready = false
        sys.publish("IP_SHUT_IND")
    end
    if net.getState() ~= 'REGISTERED' then return end
    request('AT+CGATT?')
end)

ril.regurc("STATE", function(data)
    local status = data:sub(8, -1)
    log.info("link.STATE", "IP STATUS", status)
    ready = status == "IP PROCESSING" or status == "IP STATUS"
    if status == 'PDP DEACT' then
        sys.timer_stop(queryStatus)
        request('AT+CIPSHUT') -- 执行CIPSHUT将状态恢复至IP INITIAL
        return
    elseif status == "IP INITIAL" then
        if net.getState() ~= 'REGISTERED' then return end
        request(string.format('AT+CSTT="%s","%s","%s"', apnname, username, password))
        request("AT+CIICR")
    elseif status == "IP START" then
        request("AT+CIICR")
    elseif status == "IP CONFIG" then
        -- nothing to do
    elseif status == "IP GPRSACT" then
        request("AT+CIFSR")
        request("AT+CIPSTATUS")
        return
    elseif status == "IP PROCESSING" or status == "IP STATUS" then
        sys.timer_stop(queryStatus)
        publish("IP_READY_IND")
        return
    end
    sys.timer_start(queryStatus, 2000)
end)
ril.regurc("+PDP", function() -- 这个URC只有PDP DEACT
    ready = false
    sys.publish('IP_ERROR_IND')
    sys.timer_start(queryStatus, 2000) -- 2秒后再查询CIPSTATUS 根据IP状态来做下一步动作
end)

-- initial 只能初始化1次，这里是初始化完成标志位
local inited = false

local function initial()
    if not inited then
        inited = true
        request("AT+CIICRMODE=2") --ciicr异步
        request("AT+CIPMUX=1") --多链接
        request("AT+CIPHEAD=1")
        request("AT+CIPQSEND=0") --发送模式
    end
end

-- 网络注册成功 发起GPRS附着状态查询
sys.subscribe("NET_STATE_REGISTERED", function()
    initial()
    request('AT+CGATT?')
end)
