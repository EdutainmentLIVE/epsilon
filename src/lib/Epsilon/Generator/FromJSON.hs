module Epsilon.Generator.FromJSON
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
  constructor <- case Type.constructors type_ of
    [x] -> pure x
    _ -> Hsc.throwError srcSpan $ Ghc.text "requires exactly one constructor"
  modifyFieldName <-
    Common.applyAll
      <$> Options.parse (Common.fieldNameOptions srcSpan) options srcSpan

  fields <-
    mapM (fromField srcSpan modifyFieldName)
    . concatMap Constructor.fields
    $ Type.constructors type_

  applicative <- Common.makeRandomModule Module.control_applicative
  aeson <- Common.makeRandomModule Module.data_aeson
  text <- Common.makeRandomModule Module.data_text
  object <- Common.makeRandomVariable srcSpan "object_"
  let
    lImportDecls = Hs.importDecls
      srcSpan
      [ (Module.control_applicative, applicative)
      , (Module.data_aeson, aeson)
      , (Module.data_text, text)
      ]

    bindStmts = fmap
      (\(field, (name, var)) ->
        Hs.bindStmt srcSpan (Hs.varPat srcSpan var)
          . Hs.opApp
              srcSpan
              (Hs.var srcSpan object)
              (Hs.qualVar srcSpan aeson
              . Ghc.mkVarOcc
              $ if Field.isOptional field then ".:?" else ".:"
              )
          . Hs.app srcSpan (Hs.qualVar srcSpan text $ Ghc.mkVarOcc "pack")
          . Hs.lit srcSpan
          $ Hs.string name
      )
      fields

    lastStmt =
      Hs.lastStmt srcSpan
        . Hs.app srcSpan (Hs.qualVar srcSpan applicative $ Ghc.mkVarOcc "pure")
        . Hs.recordCon srcSpan (Ghc.L srcSpan $ Constructor.name constructor)
        . Hs.recFields
        $ fmap
            (\(field, (_, var)) ->
              Hs.recField
                  srcSpan
                  (Hs.fieldOcc srcSpan . Hs.unqual srcSpan $ Field.name field)
                $ Hs.var srcSpan var
            )
            fields

    lHsBind =
      Common.makeLHsBind srcSpan (Ghc.mkVarOcc "parseJSON") []
        . Hs.app
            srcSpan
            (Hs.app
                srcSpan
                (Hs.qualVar srcSpan aeson $ Ghc.mkVarOcc "withObject")
            . Hs.lit srcSpan
            . Hs.string
            $ Type.qualifiedName moduleName type_
            )
        . Hs.par srcSpan
        . Hs.lam srcSpan
        . Hs.mg
        $ Ghc.L
            srcSpan
            [ Hs.match srcSpan Ghc.LambdaExpr [Hs.varPat srcSpan object]
                $ Hs.grhss
                    srcSpan
                    [ Hs.grhs srcSpan
                      . Hs.doExpr srcSpan
                      $ bindStmts
                      <> [lastStmt]
                    ]
            ]

    lHsDecl = Common.makeInstanceDeclaration
      srcSpan
      type_
      aeson
      (Ghc.mkClsOcc "FromJSON")
      [lHsBind]

  pure (lImportDecls, [lHsDecl])

fromField
  :: Ghc.SrcSpan
  -> (String -> Ghc.Hsc String)
  -> Field.Field
  -> Ghc.Hsc (Field.Field, (String, Ghc.LIdP Ghc.GhcPs))
fromField srcSpan modifyFieldName field = do
  let fieldName = Field.name field
  name <- modifyFieldName $ Ghc.occNameString fieldName
  var <- Common.makeRandomVariable srcSpan . (<> "_") $ Ghc.occNameString
    fieldName
  pure (field, (name, var))
