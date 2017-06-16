{-|
  Copyright  :  (C) 2015-2016, University of Twente
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}

{-# OPTIONS_HADDOCK show-extensions #-}

module CLaSH.Driver.TopWrapper where

import           Data.Text.Lazy       (append, pack)

import CLaSH.Annotations.TopEntity    (TopEntity (..), PortName (..))

import CLaSH.Netlist.Types
  (Component (..), Declaration (..), Expr (..), Identifier, HWType (..),
   Modifier (..), PortDirection(..))
import CLaSH.Util

-- | Create a wrapper around a component, potentially initiating clock sources
mkTopWrapper :: (Identifier -> Identifier)
             -> Maybe TopEntity -- ^ TopEntity specifications
             -> String          -- ^ Name of the module containing the @topEntity@
             -> Component       -- ^ Entity to wrap
             -> Component
mkTopWrapper mkId teM modName topComponent
  = Component
  { componentName = maybe (mkId (pack modName `append` "_topEntity")) (pack . t_name) teM
  , inputs        = inputs3 ++ extraIn teM
  , outputs       = outputs3 ++ extraOut teM
  , hiddenPorts   = topHidden
  , declarations  = concat [wrappers,topCompDecl:unwrappers]
  }
  where
    topHidden = hiddenPorts topComponent

    -- input ports
    iPortSupply    = maybe (repeat Nothing)
                           (extendPorts . t_inputs)
                           teM
    inputs1        = map (first (const "input"))
                         (inputs topComponent)
    inputs2        = zipWith mkInput iPortSupply
                             (zipWith appendNumber inputs1 [0..])
    (inputs3,wrappers,idsI) = concatPortDecls inputs2

    -- output ports
    oPortSupply    = maybe (repeat Nothing)
                           ((++ repeat Nothing) . map Just . t_outputs)
                           teM
    outputs1       = map (first (const "output"))
                         (outputs topComponent)
    outputs2       = zipWith mkOutput oPortSupply
                             (zipWith appendNumber outputs1 [0..])
    (outputs3,unwrappers,idsO) = concatPortDecls outputs2

    -- instantiate the top-level component
    topCompDecl =
      InstDecl (componentName topComponent)
               (componentName topComponent `append` "_inst")
               (zipWith (\(p,t) i -> (p,In,t,Identifier i Nothing))
                        (inputs topComponent)
                        idsI
                ++
                map (\(p,t) -> (p,In,t,Identifier p Nothing))
                    topHidden
                ++
                zipWith (\(p,t) o -> (p,Out,t,Identifier o Nothing))
                        (outputs topComponent)
                        idsO)

extendPorts :: [PortName] -> [Maybe PortName]
extendPorts ps = map Just ps ++ repeat Nothing

concatPortDecls
  :: [([(Identifier,HWType)],[Declaration],Identifier)]
  -> ([(Identifier,HWType)],[Declaration],[Identifier])
concatPortDecls portDecls = case unzip3 portDecls of
  (ps,decls,ids) -> (concat ps, concat decls, ids)

appendNumber
  :: (Identifier,HWType)
  -> Int
  -> (Identifier,HWType)
appendNumber (nm,hwty) i =
  (nm `append` "_" `append` pack (show i),hwty)

-- | Create extra input ports for the wrapper
extraIn :: Maybe TopEntity -> [(Identifier,HWType)]
extraIn = maybe [] ((map (pack *** BitVector)) . t_extraIn)

-- | Create extra output ports for the wrapper
extraOut :: Maybe TopEntity -> [(Identifier,HWType)]
extraOut = maybe [] ((map (pack *** BitVector)) . t_extraOut)


portName
  :: String
  -> Identifier
  -> Identifier
portName [] i = i
portName x  _ = pack x

mkInput
  :: Maybe PortName
  -> (Identifier,HWType)
  -> ([(Identifier,HWType)],[Declaration],Identifier)
mkInput pM = case pM of
  Nothing -> go
  Just p  -> go' p
  where
    go (i,hwty) = case hwty of
      Vector sz hwty' -> (ports,netdecl:netassgn:decls,i)
        where
          inputs1  = map (appendNumber (i,hwty')) [0..(sz-1)]
          inputs2  = map (mkInput Nothing) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          netdecl  = NetDecl i hwty
          netassgn = Assignment i (mkVectorChain sz hwty' ids)

      RTree d hwty' -> (ports,netdecl:netassgn:decls,i)
        where
          inputs1  = map (appendNumber (i,hwty')) [0..((2^d)-1)]
          inputs2  = map (mkInput Nothing) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          netdecl  = NetDecl i hwty
          netassgn = Assignment i (mkRTreeChain d hwty' ids)

      Product _ hwtys -> (ports,netdecl:netassgn:decls,i)
        where
          inputs1  = zipWith appendNumber (map (i,) hwtys) [0..]
          inputs2  = map (mkInput Nothing) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          ids'     = map (`Identifier` Nothing) ids
          netdecl  = NetDecl i hwty
          netassgn = Assignment i (DataCon hwty (DC (hwty,0)) ids')

      _ -> ([(i,hwty)],[],i)

    go' (PortName p)     (i,hwty) = let pN = portName p i in ([(pN,hwty)],[],pN)
    go' (PortField p ps) (i,hwty) = let pN = portName p i in case hwty of
      Vector sz hwty' -> (ports,netdecl:netassgn:decls,pN)
        where
          inputs1  = map (appendNumber (pN,hwty')) [0..(sz-1)]
          inputs2  = zipWith mkInput (extendPorts ps) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          netdecl  = NetDecl pN hwty
          netassgn = Assignment pN (mkVectorChain sz hwty' ids)

      RTree d hwty' -> (ports,netdecl:netassgn:decls,pN)
        where
          inputs1  = map (appendNumber (pN,hwty')) [0..((2^d)-1)]
          inputs2  = zipWith mkInput (extendPorts ps) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          netdecl  = NetDecl pN hwty
          netassgn = Assignment pN (mkRTreeChain d hwty' ids)

      Product _ hwtys -> (ports,netdecl:netassgn:decls,pN)
        where
          inputs1  = zipWith appendNumber (map (pN,) hwtys) [0..]
          inputs2  = zipWith mkInput (extendPorts ps) inputs1
          (ports,decls,ids) = concatPortDecls inputs2
          ids'     = map (`Identifier` Nothing) ids
          netdecl  = NetDecl pN hwty
          netassgn = Assignment pN (DataCon hwty (DC (hwty,0)) ids')

      _ -> ([(pN,hwty)],[],pN)


-- | Create a Vector chain for a list of 'Identifier's
mkVectorChain :: Int
              -> HWType
              -> [Identifier]
              -> Expr
mkVectorChain _ elTy []      = DataCon (Vector 0 elTy) VecAppend []
mkVectorChain _ elTy [i]     = DataCon (Vector 1 elTy) VecAppend
                                [Identifier i Nothing]
mkVectorChain sz elTy (i:is) = DataCon (Vector sz elTy) VecAppend
                                [ Identifier i Nothing
                                , mkVectorChain (sz-1) elTy is
                                ]

-- | Create a RTree chain for a list of 'Identifier's
mkRTreeChain :: Int
             -> HWType
             -> [Identifier]
             -> Expr
mkRTreeChain _ elTy [i] = DataCon (RTree 0 elTy) RTreeAppend
                                  [Identifier i Nothing]
mkRTreeChain d elTy is =
  let (isL,isR) = splitAt (length is `div` 2) is
  in  DataCon (RTree d elTy) RTreeAppend
        [ mkRTreeChain (d-1) elTy isL
        , mkRTreeChain (d-1) elTy isR
        ]

-- | Generate output port mappings
mkOutput
  :: Maybe PortName
  -> (Identifier,HWType)
  -> ([(Identifier,HWType)],[Declaration],Identifier)
mkOutput pM = case pM of
  Nothing -> go
  Just p  -> go' p
  where
    go (o,hwty) = case hwty of
      Vector sz hwty' -> (ports,netdecl:assigns ++ decls,o)
        where
          outputs1 = map (appendNumber (o,hwty')) [0..(sz-1)]
          outputs2 = map (mkOutput Nothing) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl o hwty
          assigns  = zipWith (assingId o hwty 10) ids [0..]

      RTree d hwty' -> (ports,netdecl:assigns ++ decls,o)
        where
          outputs1 = map (appendNumber (o,hwty')) [0..((2^d)-1)]
          outputs2 = map (mkOutput Nothing) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl o hwty
          assigns  = zipWith (assingId o hwty 10) ids [0..]

      Product _ hwtys -> (ports,netdecl:assigns ++ decls,o)
        where
          outputs1 = zipWith appendNumber (map (o,) hwtys) [0..]
          outputs2 = map (mkOutput Nothing) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl o hwty
          assigns  = zipWith (assingId o hwty 0) ids [0..]

      _ -> ([(o,hwty)],[],o)

    go' (PortName p)     (i,hwty) = let pN = portName p i in ([(pN,hwty)],[],pN)
    go' (PortField p ps) (i,hwty) = let pN = portName p i in case hwty of
      Vector sz hwty' -> (ports,netdecl:assigns ++ decls,pN)
        where
          outputs1 = map (appendNumber (pN,hwty')) [0..(sz-1)]
          outputs2 = zipWith mkOutput (extendPorts ps) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl pN hwty
          assigns  = zipWith (assingId pN hwty 10) ids [0..]

      RTree d hwty' -> (ports,netdecl:assigns ++ decls,pN)
        where
          outputs1 = map (appendNumber (pN,hwty')) [0..((2^d)-1)]
          outputs2 = zipWith mkOutput (extendPorts ps) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl pN hwty
          assigns  = zipWith (assingId pN hwty 10) ids [0..]

      Product _ hwtys -> (ports,netdecl:assigns ++ decls,pN)
        where
          outputs1 = zipWith appendNumber (map (pN,) hwtys) [0..]
          outputs2 = zipWith mkOutput (extendPorts ps) outputs1
          (ports,decls,ids) = concatPortDecls outputs2
          netdecl  = NetDecl pN hwty
          assigns  = zipWith (assingId pN hwty 0) ids [0..]

      _ -> ([(pN,hwty)],[],pN)

    assingId p hwty con i n =
      Assignment i (Identifier p (Just (Indexed (hwty,con,n))))
