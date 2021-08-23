module Epsilon.Generator.ToSchema
  ( generate
  ) where

import qualified Epsilon.Constant.Module as Module
import qualified Epsilon.Generator.Common as Common
import qualified Epsilon.Hs as Hs
import qualified Epsilon.Hsc as Hsc
import qualified Epsilon.Options as Options
import qualified Epsilon.Type.Constructor as Constructor
import qualified Epsilon.Type.Field as Field
import qualified Epsilon.Type.Type as Type
import qualified GHC.Hs as Ghc
import qualified GhcPlugins as Ghc

generate :: Common.Generator
generate moduleName lIdP lHsQTyVars lConDecls options srcSpan = do
  type_ <- Type.make lIdP lHsQTyVars lConDecls srcSpan
  case Type.constructors type_ of
    [_] -> pure ()
    _ -> Hsc.throwError srcSpan $ Ghc.text "requires exactly one constructor"

  modifyFieldName <-
    Common.applyAll
      <$> Options.parse (Common.fieldNameOptions srcSpan) options srcSpan

  fields <-
    mapM (fromField srcSpan modifyFieldName)
    . concatMap Constructor.fields
    $ Type.constructors type_

  applicative <- Common.makeRandomModule Module.control_applicative
  lens <- Common.makeRandomModule Module.control_lens
  hashMap <- Common.makeRandomModule Module.data_hashMap_strict_insOrd
  dataMaybe <- Common.makeRandomModule Module.data_maybe
  monoid <- Common.makeRandomModule Module.data_monoid
  proxy <- Common.makeRandomModule Module.data_proxy
  swagger <- Common.makeRandomModule Module.data_swagger
  text <- Common.makeRandomModule Module.data_text
  ignored <- Common.makeRandomVariable srcSpan "_proxy_"
  let
    lImportDecls = Hs.importDecls
      srcSpan
      [ (Module.control_applicative, applicative)
      , (Module.control_lens, lens)
      , (Module.data_hashMap_strict_insOrd, hashMap)
      , (Module.data_maybe, dataMaybe)
      , (Module.data_monoid, monoid)
      , (Module.data_proxy, proxy)
      , (Module.data_swagger, swagger)
      , (Module.data_text, text)
      ]

    toBind field var =
      Hs.bindStmt srcSpan (Hs.varPat srcSpan var)
        . Hs.app
            srcSpan
            (Hs.qualVar srcSpan swagger $ Ghc.mkVarOcc "declareSchemaRef")
        . Hs.par srcSpan
        . Ghc.L srcSpan
        . Ghc.ExprWithTySig
            Ghc.noExtField
            (Hs.qualVar srcSpan proxy $ Ghc.mkDataOcc "Proxy")
        . Ghc.HsWC Ghc.noExtField
        . Ghc.HsIB Ghc.noExtField
        . Ghc.L srcSpan
        . Ghc.HsAppTy
            Ghc.noExtField
            (Hs.qualTyVar srcSpan proxy $ Ghc.mkClsOcc "Proxy")
        . Ghc.L srcSpan
        . Ghc.HsParTy Ghc.noExtField
        . Ghc.L srcSpan
        $ Field.type_ field -- TODO: This requires `ScopedTypeVariables`.

    bindStmts = fmap (\((field, _), var) -> toBind field var) fields

    setType =
      Hs.opApp
          srcSpan
          (Hs.qualVar srcSpan swagger $ Ghc.mkVarOcc "type_")
          (Hs.qualVar srcSpan lens $ Ghc.mkVarOcc "?~")
        . Hs.qualVar srcSpan swagger
        $ Ghc.mkDataOcc "SwaggerObject"

    setProperties =
      Hs.opApp
          srcSpan
          (Hs.qualVar srcSpan swagger $ Ghc.mkVarOcc "properties")
          (Hs.qualVar srcSpan lens $ Ghc.mkVarOcc ".~")
        . Hs.app srcSpan (Hs.qualVar srcSpan hashMap $ Ghc.mkVarOcc "fromList")
        . Hs.explicitList srcSpan
        $ fmap
            (\((_, name), var) -> Hs.explicitTuple srcSpan $ fmap
              (Hs.tupArg srcSpan)
              [ Hs.app srcSpan (Hs.qualVar srcSpan text $ Ghc.mkVarOcc "pack")
              . Hs.lit srcSpan
              $ Hs.string name
              , Hs.var srcSpan var
              ]
            )
            fields

    setRequired =
      Hs.opApp
          srcSpan
          (Hs.qualVar srcSpan swagger $ Ghc.mkVarOcc "required")
          (Hs.qualVar srcSpan lens $ Ghc.mkVarOcc ".~")
        . Hs.explicitList srcSpan
        . fmap
            (Hs.app srcSpan (Hs.qualVar srcSpan text $ Ghc.mkVarOcc "pack")
            . Hs.lit srcSpan
            . Hs.string
            . snd
            . fst
            )
        $ filter (not . Field.isOptional . fst . fst) fields

    lastStmt =
      Hs.lastStmt srcSpan
        . Hs.app srcSpan (Hs.qualVar srcSpan applicative $ Ghc.mkVarOcc "pure")
        . Hs.par srcSpan
        . Hs.app
            srcSpan
            (Hs.app
                srcSpan
                (Hs.qualVar srcSpan swagger $ Ghc.mkDataOcc "NamedSchema")
            . Hs.par srcSpan
            . Hs.app
                srcSpan
                (Hs.qualVar srcSpan dataMaybe $ Ghc.mkDataOcc "Just")
            . Hs.par srcSpan
            . Hs.app srcSpan (Hs.qualVar srcSpan text $ Ghc.mkVarOcc "pack")
            . Hs.lit srcSpan
            . Hs.string
            $ Type.qualifiedName moduleName type_
            )
        . Hs.par srcSpan
        . makePipeline srcSpan lens [setType, setProperties, setRequired]
        . Hs.qualVar srcSpan monoid
        $ Ghc.mkVarOcc "mempty"

    lHsBind =
      Common.makeLHsBind
          srcSpan
          (Ghc.mkVarOcc "declareNamedSchema")
          [Hs.varPat srcSpan ignored]
        . Hs.doExpr srcSpan
        $ bindStmts
        <> [lastStmt]

    lHsDecl = Common.makeInstanceDeclaration
      srcSpan
      type_
      swagger
      (Ghc.mkClsOcc "ToSchema")
      [lHsBind]

  pure (lImportDecls, [lHsDecl])

fromField
  :: Ghc.SrcSpan
  -> (String -> Ghc.Hsc String)
  -> Field.Field
  -> Ghc.Hsc ((Field.Field, String), Ghc.LIdP Ghc.GhcPs)
fromField srcSpan modifyFieldName field = do
  let fieldName = Field.name field
  name <- modifyFieldName $ Ghc.occNameString fieldName
  var <- Common.makeRandomVariable srcSpan . (<> "_") $ Ghc.occNameString
    fieldName
  pure ((field, name), var)

makePipeline
  :: Ghc.SrcSpan
  -> Ghc.ModuleName
  -> [Ghc.LHsExpr Ghc.GhcPs]
  -> Ghc.LHsExpr Ghc.GhcPs
  -> Ghc.LHsExpr Ghc.GhcPs
makePipeline srcSpan m es e = case es of
  [] -> e
  h : t -> makePipeline srcSpan m t
    $ Hs.opApp srcSpan e (Hs.qualVar srcSpan m $ Ghc.mkVarOcc "&") h
