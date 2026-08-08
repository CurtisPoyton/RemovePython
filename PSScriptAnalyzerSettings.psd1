@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        'PSDSCDscExamplesPresent',
        'PSDSCDscTestsPresent',
        'PSDSCReturnCorrectTypesForDSCFunctions',
        'PSDSCStandardDSCFunctionsInResource',
        'PSDSCUseIdenticalMandatoryParametersForDSC',
        'PSDSCUseIdenticalParametersForDSC',
        'PSDSCUseVerboseMessageInDSCResource',
        'PSUseCompatibleCmdlets',
        'PSUseCompatibleCommands',
        'PSUseCompatibleTypes'
    )

    Rules        = @{
        PSAlignAssignmentStatement                = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSAvoidExclaimOperator                    = @{
            Enable = $true
        }

        PSAvoidLongLines                          = @{
            Enable            = $true
            MaximumLineLength = 120
        }

        PSAvoidSemicolonsAsLineTerminators        = @{
            Enable = $true
        }

        PSAvoidUsingDoubleQuotesForConstantString = @{
            Enable = $true
        }

        PSPlaceCloseBrace                         = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $true
        }

        PSPlaceOpenBrace                          = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSProvideCommentHelp                      = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }

        PSUseCompatibleSyntax                     = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }

        PSUseConsistentIndentation                = @{
            Enable              = $true
            IndentationSize     = 4
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace                 = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckParameter                          = $false
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSUseCorrectCasing                        = @{
            Enable = $true
        }
    }
}
