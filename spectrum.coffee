#Designed to operate on cryptotrader.org
#The following code is Copyright © 2017 Michael James Coffey
startingParameters = require "params"
talib = require "talib"
trading = require "trading"

#Buffer as a function of current average price
bufferPC = startingParameters.add "Market Scope %", 0.5

#Starting position from spread as a function of average price
spreadStartPC = startingParameters.add "Spread %", 0.1

#Number of bid positions
numBidPos = startingParameters.add "Number of bid positions (min 2)", 5

#Number of ask positions
numAskPos = startingParameters.add "Number of ask positions (min 2)", 5

#Profit margin percent
profitMargin = startingParameters.add "Profit margin", 1.01

#Bid delta bias
#Profit margin percent
bidDelBias = startingParameters.add "Bid delta bias", 8

MINIMUM_AMOUNT = .1

#Cryptocurrency trade block remembers minimum ask for cryptocurrency; created initially and whenever cryptocurrency is purchased
class cryptoTBlock
    constructor: (amount, minAsk) ->
        @amount = amount
        @minAsk = minAsk

#Function to generate trade positions
generatePositions = (numPos, delta) ->
  ###
  debug "Generating q value with numPos = #{numPos}"
  ###

  q = (delta + 1) * Math.pow(2, -numPos)

  ###
  debug "q value: #{q}"
  ###

  devArr = new Array(numPos)
  i = 0
  while i < numPos
    devArr[i] = q * (Math.pow(2, i) - 1)
    i++
  devArr

#Function to generate trade volumes
generateVolumes = (numPos) ->
  amtPCArr = new Array(numPos)
  sumAmtPCArr = 0
  i = 0
  while i < numPos
    amtPCArr[i] = Math.log(i + 2)
    sumAmtPCArr += amtPCArr[i]
    i++
  i = 0
  while i < numPos
    amtPCArr[i] = (amtPCArr[i] / sumAmtPCArr)-0.01
    i++
  amtPCArr

init: ->
    #Initialize spectrum
    context.prevSpectrum = 0

    #Initialize array of trade blocks
    context.cryptoTBlockArr = new Array()
    context.firstRun = 1
    storage.cycle = 0

    context.bidOrders = new Array()
    context.askOrders = new Array()


    setPlotOptions
        bid:
            color: 'red'
        marker:
            color: 'blue'
        ask:
            color: 'green'


handle: ->
    #Housekeeping variables
    primaryInstrument = data.instruments[0]
    info "Cycle: #{storage.cycle}"
    storage.cycle++

    #Create trade blocks for current assets; set amount to currently held assets; set the minAsk to current price
    #New blocks will hereforth be created from fulfilling bid orders
    if(context.firstRun == 1)
        context.cryptoTBlockArr = []
        if(@portfolios[primaryInstrument.market].positions[primaryInstrument.asset()].amount > 1)
            ###
            debug "Creating initial CTB"
            ###
            context.cryptoTBlockArr.push(new cryptoTBlock(@portfolios[primaryInstrument.market].positions[primaryInstrument.asset()].amount, primaryInstrument.price))
        context.firstRun = 0

    #Calculate sprectrum; represents our expected deviation from average
    currSpectrum = context.prevSpectrum/2 + 0.01*bufferPC*primaryInstrument.price
    context.prevSpectrum = primaryInstrument.high[primaryInstrument.high.length-1] - primaryInstrument.low[primaryInstrument.low.length-1]

    ###
    debug "Spectrum: #{currSpectrum}"
    ###

    #Calculate the market maker's spread from settings; this represents the deviation from the price in which the first order is placed
    spread = primaryInstrument.price*0.01*spreadStartPC

    #Create trading positions from spectrum; the positions will begin at the spread, and double until the end of the spectrum
    delta = currSpectrum - spread #Represents the difference in where we can place our trading positions

    ###
    debug "Delta: #{delta}"
    debug "Price: #{primaryInstrument.price}"
    debug "Spread: #{spread}"
    ###

    #For bids
    bidArr = generatePositions(numBidPos, delta)
    i = 0
    while i < bidArr.length
        #Implement bid delta bias
        bidArr[i] = primaryInstrument.price - (bidDelBias*(spread + bidArr[i]))
        ###
        debug "Bid number #{i}" 
        debug "at #{bidArr[i]}"
        ###
        i++
    #For asks
    askArr = generatePositions(numAskPos, delta)
    i = 0
    while i < askArr.length
        askArr[i] = primaryInstrument.price + spread + askArr[i]
        ###
        debug "Ask number #{i}" 
        debug "at #{askArr[i]}"
        ###
        i++


    #Trading logic section of code

    #Evaluate successful bids; create corresponding crypto trade blocks; cancel currently active bids
    if(context.bidOrders.length > 0)
        i = 0
        while i < context.bidOrders.length
            if(!context.bidOrders[i].filled)
                #We cancel the order if it exists
                ###
                debug "Cancelling bid"
                ###
                trading.cancelOrder(context.bidOrders[i])
            else
                #We create a trade block if it doesn't (means it's been fulfilled)
                ###
                debug "Creating crypto trade block"
                ###
                context.cryptoTBlockArr.push new cryptoTBlock(context.bidOrders[i].amount, context.bidOrders[i].price*profitMargin)
            i++
        context.bidOrders = []


    #Evaluate current currency, now that all bids are canceled
    amtCurrency = @portfolios[primaryInstrument.market].positions[primaryInstrument.curr()].amount

    #Debug trade blocks
    context.cryptoTBlockArr.sort (a, b) ->
        a.minAsk - (b.minAsk)

    ###
    i = 0
    debug "Trade Blocks: MinAsk; Amount"
    while i < context.cryptoTBlockArr.length
        debug "#{context.cryptoTBlockArr[i].minAsk}; #{context.cryptoTBlockArr[i].amount}"
        i++
    ###


    #Generate array that governs the capital of our bid allocation about the bid positions
    amtPCBidArr = generateVolumes(numBidPos)

    #Place bids according to allocation array
    i = 0
    while i < numBidPos
        if amtCurrency*amtPCBidArr[i]/bidArr[i] > MINIMUM_AMOUNT and amtCurrency > amtCurrency*amtPCBidArr[i]
	        order = trading.addOrder 
	            instrument: primaryInstrument
	            side: 'buy'
	            type: 'limit'
	            amount: amtCurrency*amtPCBidArr[i]/bidArr[i]
	            price: bidArr[i]
            context.bidOrders.push order
            amtCurrency -= amtCurrency*amtPCBidArr[i]
        i++


    #Create ask positions for later filling
    amtPCAskArr = generateVolumes(numAskPos)



    #Cancel ask orders and create crypto trade blocks if within market scope
    i = 0
    while i < context.askOrders.length
        #Iterate over trading block ledger
        order = context.askOrders[i]
        #Cancel active ask orders within market range, create new trade block
        if (!order.filled and order.amount < amtPCAskArr[numAskPos+1])
            ###
            debug "Ask canceled"
            ###
            context.cryptoTBlockArr.push(order.amount, order.price)
            context.askOrders[i].splice(i, 1)
            trading.cancelOrder(order)
        i++


    #Evaluate current assets, now that all asks are canceled
    amtAssets = @portfolios[primaryInstrument.market].positions[primaryInstrument.asset()].amount




    #Place asks according to allocation array

    x = 0
    while x < numAskPos
        u = 0
        amountAllc = 0
        targetAmt = Math.max(amtAssets*primaryInstrument.price*amtPCAskArr[x]/askArr[x], MINIMUM_AMOUNT)
        targetPrice = askArr[x]
        bought = 0
        tempCTBArr = new Array()
	    #Sort crypto trade blocks
        context.cryptoTBlockArr.sort (a, b) ->
            a.minAsk - (b.minAsk)

        #We must now match the trade blocks with the ask positions; we begin with the first block that meets our value
        while u < context.cryptoTBlockArr.length and bought == 0
            #If the specific trade block meets the minimum, allocate it and delete
            if ((targetPrice > context.cryptoTBlockArr[u].minAsk))
                amountAllc += context.cryptoTBlockArr[u].amount
                context.cryptoTBlockArr.splice(u, 1)
                ###
                debug "Allocated trade block, now at #{amountAllc} of #{targetAmt}"
                ###
            
            #If our allocation is done, or we run out of blocks, make the trade
            if((amountAllc >= targetAmt or u == ((context.cryptoTBlockArr.length) - 1)) and amountAllc > MINIMUM_AMOUNT and amtAssets > Math.min(amountAllc, targetAmt))
                order = trading.addOrder 
                    instrument: primaryInstrument
                    side: 'sell'
                    type: 'limit'
                    amount: Math.min(amountAllc, targetAmt)
                    price: targetPrice
                amtAssets -= Math.min(amountAllc, targetAmt)
                context.askOrders.push order
                ###
                debug "Trade made"
                ###
                bought = 1

            #Create a new trade block for the remainder
            if (amountAllc > targetAmt) 
                tempCTBArr.push new cryptoTBlock((amountAllc - targetAmt), targetPrice, false)
                ###
                debug "Created excess trade block"
                ###
            u++
        context.cryptoTBlockArr = context.cryptoTBlockArr.concat tempCTBArr
        x++

    #Remove excessive trade blocks
    if context.cryptoTBlockArr.length > 30
        context.cryptoTBlockArr.splice(30)


    #Fancy debug output
    debug "―――――― ♅ SPECTRUM v0.1 ♅ ――――――"
    debug "Current assets: #{amtAssets}"
    debug "Current currency: #{amtCurrency}"