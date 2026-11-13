#requires -Version 5.1
<#
.SYNOPSIS
    Organizer - sorts the files in your Downloads folder into tidy folders, safely.

.DESCRIPTION
    Start it by double-clicking Organizer.cmd.
      Organize    preview where every file will go, then move them with one click
      Categories  edit the built-in categories or add your own with a custom folder
      History     undo any previous run
      Settings    folder to organize, date folders, smart detection and theme

    All sorting rules and file operations live in OrganizerEngine.psm1 (same folder).
    Settings and history: %LOCALAPPDATA%\Organizer

.PARAMETER PreviewTo
    Used for testing: renders one page to a PNG file and exits.
#>
[CmdletBinding()]
param(
    [string]$PreviewTo,
    [string]$PreviewPage = 'organize',
    [string]$PreviewTheme,
    [string]$PreviewAction
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.0'
$script:EnginePath = Join-Path $PSScriptRoot 'OrganizerEngine.psm1'

# WPF needs a single-threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

try { Import-Module -Name $script:EnginePath -Force -DisableNameChecking -ErrorAction Stop }
catch {
    [void][System.Windows.MessageBox]::Show(
        ("Organizer could not start because its engine did not load:`r`n`r`n{0}`r`n`r`nKeep OrganizerEngine.psm1 in the same folder as Organizer.ps1." -f $_.Exception.Message),
        'Organizer', 'OK', 'Error')
    return
}

$script:Mutex = $null
if (-not $PreviewTo) {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\Programix.Organizer')
    $owned = $false
    try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        [void][System.Windows.MessageBox]::Show('Organizer is already open.', 'Organizer', 'OK', 'Information')
        return
    }
}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace OrganizerNative {
    public static class Dwm {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        public static void Set(IntPtr hwnd, int attribute, int value) {
            try { DwmSetWindowAttribute(hwnd, attribute, ref value, 4); } catch { }
        }
    }
}
'@
}
catch { }

# ------------------------------------------------------------------------------------------------
#  Look
# ------------------------------------------------------------------------------------------------
$script:Palettes = @{
    Dark  = @{
        Bg = '#111827'; Card = '#192333'; CardHover = '#202E40'; Border = '#2B3849'; Text = '#FFFFFF'; Muted = '#A0B1C6'
        Accent = '#1EA490'; AccentText = '#56D4BE'; AccentSoft = '#1E403C'; OnAccent = '#FFFFFF'; Line = '#263345'
        Input = '#131C2B'; Danger = '#F66060'; NavSel = '#1B4145'; Hover = '#14FFFFFF'; Scroll = '#3A4A60'
    }
    Light = @{
        Bg = '#F4F7FB'; Card = '#FFFFFF'; CardHover = '#F1F4F8'; Border = '#DDE3EA'; Text = '#1A1A1A'; Muted = '#5F6B7A'
        Accent = '#129682'; AccentText = '#0A7E6E'; AccentSoft = '#D4F0EA'; OnAccent = '#FFFFFF'; Line = '#E6EAF0'
        Input = '#FFFFFF'; Danger = '#D63E3E'; NavSel = '#D4ECE9'; Hover = '#12000000'; Scroll = '#C3CCD8'
    }
}
$script:Swatches = '#4FA3F7', '#B37BF2', '#F178B6', '#F2A742', '#4CC38A', '#F2784B', '#C9A227', '#6C8CF5', '#2CC5D2', '#E667D0', '#7BC96F', '#8794A8'

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Organizer" Width="1140" Height="740" MinWidth="960" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Geometry x:Key="FolderGeo">M2,6 A2,2 0 0 1 4,4 H9 L11.5,6.5 H20 A2,2 0 0 1 22,8.5 V18 A2,2 0 0 1 20,20 H4 A2,2 0 0 1 2,18 Z</Geometry>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8"/>
              <Border x:Name="hover" Background="{DynamicResource Hover}" CornerRadius="8" Opacity="0"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hover" Property="Opacity" Value="1"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="hover" Property="Opacity" Value="0.4"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
    </Style>
    <Style x:Key="Chip" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{Binding Fill}" BorderBrush="{Binding Stroke}" BorderThickness="1" CornerRadius="15" Height="30" Padding="11,0,12,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="Nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="9">
              <StackPanel Orientation="Horizontal" Margin="14,0">
                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="17" VerticalAlignment="Center" Width="34"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource NavSel}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="{DynamicResource Input}" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="8" Height="34" Padding="16,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource NavSel}"/>
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Swatch" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="GroupName" Value="Swatch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Width="28" Height="28" Background="Transparent">
              <Ellipse x:Name="ring" Stroke="{TemplateBinding Background}" StrokeThickness="2" Visibility="Hidden"/>
              <Ellipse Width="16" Height="16" Fill="{TemplateBinding Background}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="ring" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="{DynamicResource Muted}" Background="Transparent" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 3.5,8.5 L 7,12 L 13,5" Stroke="{DynamicResource OnAccent}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed" Margin="-1.5,-1.5,0,0"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="{DynamicResource Input}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Margin="3,2" Background="{DynamicResource Scroll}"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style x:Key="Row" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="Transparent" CornerRadius="8"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource CardHover}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="RowSel" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="Transparent" CornerRadius="8" Margin="0,0,0,2"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource CardHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource NavSel}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{DynamicResource Line}" CornerRadius="3"/>
              <Border x:Name="PART_Indicator" Background="{DynamicResource Accent}" CornerRadius="3" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/><Setter Property="FontSize" Value="23"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/><Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Caps" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Bold"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Navigation rail -->
    <DockPanel Margin="16,20,10,16" LastChildFill="False">
      <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="8,0,0,26">
        <Border Width="38" Height="38" CornerRadius="10">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#2BC7A9" Offset="0"/><GradientStop Color="#3B6FE0" Offset="1"/></LinearGradientBrush>
          </Border.Background>
          <Path Data="{StaticResource FolderGeo}" Fill="White" Width="20" Height="16" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock Text="Organizer" FontFamily="Segoe UI Semibold" FontSize="15" VerticalAlignment="Center" Margin="13,0,0,0"/>
      </StackPanel>
      <RadioButton x:Name="NavOrganize" DockPanel.Dock="Top" Style="{StaticResource Nav}" Tag="&#xE896;" Content="Organize" IsChecked="True"/>
      <RadioButton x:Name="NavCategories" DockPanel.Dock="Top" Style="{StaticResource Nav}" Tag="&#xE8EC;" Content="Categories"/>
      <RadioButton x:Name="NavHistory" DockPanel.Dock="Top" Style="{StaticResource Nav}" Tag="&#xE81C;" Content="History"/>
      <RadioButton x:Name="NavSafety" DockPanel.Dock="Top" Style="{StaticResource Nav}" Tag="&#xE72E;" Content="Safety"/>
      <RadioButton x:Name="NavSettings" DockPanel.Dock="Bottom" Style="{StaticResource Nav}" Tag="&#xE713;" Content="Settings" Margin="0"/>
    </DockPanel>

    <!-- ============================== Organize ============================== -->
    <Grid x:Name="PageOrganize" Grid.Column="1" Margin="14,22,28,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock x:Name="OrganizeTitle" Style="{StaticResource H1}" Text="Organize your Downloads"/>
          <TextBlock x:Name="SourceText" Style="{StaticResource Sub}" Margin="0,5,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnOpenSource" Style="{StaticResource Btn}" Margin="0,0,8,0" ToolTip="Open the folder in File Explorer">
            <StackPanel Orientation="Horizontal"><Path Data="{StaticResource FolderGeo}" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.4" StrokeLineJoin="Round" Width="16" Height="13" Stretch="Uniform" VerticalAlignment="Center" Margin="0,0,9,0"/><TextBlock Text="Open folder"/></StackPanel>
          </Button>
          <Button x:Name="BtnScan" Style="{StaticResource Btn}" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Scan again"/></StackPanel>
          </Button>
          <Button x:Name="BtnOrganize" Style="{StaticResource BtnPrimary}" Height="40" Padding="22,0" FontSize="14" Content="Organize"/>
        </StackPanel>
      </Grid>

      <UniformGrid Grid.Row="1" Columns="4" Margin="-6,20,-6,0">
        <Border Style="{StaticResource Card}" Margin="6,0" Padding="16,13">
          <StackPanel><TextBlock Style="{StaticResource Caps}" Text="FILES TO SORT"/><TextBlock x:Name="StatFiles" Text="0" FontFamily="Segoe UI Semibold" FontSize="22" Margin="0,4,0,0"/></StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="6,0" Padding="16,13">
          <StackPanel><TextBlock Style="{StaticResource Caps}" Text="TOTAL SIZE"/><TextBlock x:Name="StatSize" Text="0 B" FontFamily="Segoe UI Semibold" FontSize="22" Margin="0,4,0,0"/></StackPanel>
        </Border>
        <Border Style="{StaticResource Card}" Margin="6,0" Padding="16,13">
          <StackPanel><TextBlock Style="{StaticResource Caps}" Text="DESTINATION FOLDERS"/><TextBlock x:Name="StatFolders" Text="0" FontFamily="Segoe UI Semibold" FontSize="22" Margin="0,4,0,0"/></StackPanel>
        </Border>
        <Border x:Name="StatSkippedCard" Style="{StaticResource Card}" Margin="6,0" Padding="16,13" Cursor="Hand">
          <StackPanel><TextBlock Style="{StaticResource Caps}" Text="LEFT UNTOUCHED"/><TextBlock x:Name="StatSkipped" Text="0" FontFamily="Segoe UI Semibold" FontSize="22" Margin="0,4,0,0"/></StackPanel>
        </Border>
      </UniformGrid>

      <Border x:Name="Banner" Grid.Row="2" Background="{DynamicResource AccentSoft}" CornerRadius="10" Padding="16,10" Margin="0,14,0,0" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="{DynamicResource AccentText}" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <TextBlock x:Name="BannerText" Grid.Column="1" VerticalAlignment="Center" TextWrapping="Wrap"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Button x:Name="BtnBannerUndo" Style="{StaticResource Btn}" Height="32" Content="Undo" Margin="12,0,0,0"/>
            <Button x:Name="BtnBannerClose" Style="{StaticResource Btn}" Height="32" Padding="10,0" BorderThickness="0" Background="Transparent" Margin="6,0,0,0">
              <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11"/>
            </Button>
          </StackPanel>
        </Grid>
      </Border>

      <ItemsControl x:Name="ChipList" Grid.Row="3" Margin="0,16,0,0">
        <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
        <ItemsControl.ItemTemplate>
          <DataTemplate>
            <Button Style="{StaticResource Chip}" Tag="{Binding Id}">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="{Binding Color}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                <TextBlock Text="{Binding Count}" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </StackPanel>
            </Button>
          </DataTemplate>
        </ItemsControl.ItemTemplate>
      </ItemsControl>

      <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,6,0,0">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Grid Margin="14,12,14,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="280"/></Grid.ColumnDefinitions>
            <CheckBox x:Name="ChkAll" IsChecked="True" Content="Select all" VerticalAlignment="Center" Margin="8,0,0,0"/>
            <TextBlock x:Name="ShownText" Grid.Column="1" Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="18,0,0,0"/>
            <Grid Grid.Column="2">
              <TextBox x:Name="SearchBox" Padding="32,0,10,0"/>
              <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="11,0,0,0" HorizontalAlignment="Left" IsHitTestVisible="False"/>
              <TextBlock x:Name="SearchHint" Text="Search files" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="34,0,0,0" IsHitTestVisible="False"/>
            </Grid>
          </Grid>
          <Border Grid.Row="1" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,1" Padding="22,8,24,8">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition Width="3*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="150"/><ColumnDefinition Width="2.4*"/></Grid.ColumnDefinitions>
              <TextBlock Grid.Column="1" Style="{StaticResource Caps}" Text="FILE"/>
              <TextBlock Grid.Column="2" Style="{StaticResource Caps}" Text="SIZE"/>
              <TextBlock Grid.Column="3" Style="{StaticResource Caps}" Text="CATEGORY"/>
              <TextBlock Grid.Column="4" Style="{StaticResource Caps}" Text="MOVES TO"/>
            </Grid>
          </Border>
          <ListBox x:Name="PlanList" Grid.Row="2" Margin="6,6,4,6" ItemContainerStyle="{StaticResource Row}">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid Margin="16,8,10,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition Width="3*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="150"/><ColumnDefinition Width="2.4*"/></Grid.ColumnDefinitions>
                  <CheckBox IsChecked="{Binding Include, Mode=OneWay}" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Margin="0,0,14,0" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Path}"/>
                    <TextBlock Text="{Binding Reason}" Foreground="{DynamicResource Muted}" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                  </StackPanel>
                  <TextBlock Grid.Column="2" Text="{Binding SizeText}" Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
                  <Border Grid.Column="3" Background="{Binding ColorSoft}" CornerRadius="11" Height="22" Padding="10,0" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,10,0">
                    <StackPanel Orientation="Horizontal">
                      <Ellipse Width="7" Height="7" Fill="{Binding Color}" VerticalAlignment="Center" Margin="0,0,7,0"/>
                      <TextBlock Text="{Binding Category}" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                  <TextBlock Grid.Column="4" Text="{Binding DestinationText}" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" ToolTip="{Binding DestinationFolder}"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <StackPanel x:Name="EmptyState" Grid.Row="2" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
            <Border Width="64" Height="64" CornerRadius="32" Background="{DynamicResource AccentSoft}" HorizontalAlignment="Center">
              <TextBlock x:Name="EmptyIcon" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="{DynamicResource AccentText}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="EmptyTitle" Text="Everything is tidy" FontFamily="Segoe UI Semibold" FontSize="17" HorizontalAlignment="Center" Margin="0,16,0,0"/>
            <TextBlock x:Name="EmptyText" Style="{StaticResource Sub}" TextAlignment="Center" MaxWidth="420" Margin="0,6,0,0"/>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Row="5" Margin="2,12,2,0" Height="20">
        <TextBlock x:Name="FooterText" Style="{StaticResource Sub}" FontSize="12" VerticalAlignment="Center"
                   Text="Folders are never moved, nothing is deleted or overwritten, and every run can be undone."/>
        <Grid x:Name="ProgressPanel" Visibility="Collapsed">
          <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <ProgressBar x:Name="Progress" VerticalAlignment="Center"/>
          <TextBlock x:Name="ProgressText" Grid.Column="1" Style="{StaticResource Sub}" FontSize="12" VerticalAlignment="Center" Margin="14,0,0,0" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
        </Grid>
      </Grid>
    </Grid>

    <!-- ============================== Categories ============================== -->
    <Grid x:Name="PageCategories" Grid.Column="1" Margin="14,22,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel>
        <TextBlock Style="{StaticResource H1}" Text="Categories"/>
        <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,0" Text="Decide which files belong together and which folder they go to. Add your own category with any folder on your PC."/>
      </StackPanel>
      <Grid Grid.Row="1" Margin="0,20,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="310"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Margin="0,0,14,0">
          <DockPanel>
            <Button x:Name="BtnNewCategory" DockPanel.Dock="Top" Style="{StaticResource BtnPrimary}" Margin="12,12,12,8">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE710;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,9,0"/><TextBlock Text="New category"/></StackPanel>
            </Button>
            <Button x:Name="BtnRestore" DockPanel.Dock="Bottom" Style="{StaticResource Btn}" Margin="12,8,12,12" Content="Restore default categories"/>
            <ListBox x:Name="CategoryList" Margin="8,0,4,0" ItemContainerStyle="{StaticResource RowSel}">
              <ListBox.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="12,9,10,9">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Ellipse Width="10" Height="10" Fill="{Binding Color}" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                    <StackPanel Grid.Column="1">
                      <TextBlock Text="{Binding Name}" FontFamily="Segoe UI Semibold" TextTrimming="CharacterEllipsis"/>
                      <TextBlock Text="{Binding Sub}" Foreground="{DynamicResource Muted}" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                    </StackPanel>
                    <TextBlock Grid.Column="2" Text="{Binding Badge}" Foreground="{DynamicResource Muted}" FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  </Grid>
                </DataTemplate>
              </ListBox.ItemTemplate>
            </ListBox>
          </DockPanel>
        </Border>
        <Border Grid.Column="1" Style="{StaticResource Card}">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="24,20,24,20">
              <TextBlock x:Name="EditorTitle" FontFamily="Segoe UI Semibold" FontSize="17" Text="Category"/>
              <TextBlock x:Name="EditorNote" Style="{StaticResource Sub}" Margin="0,4,0,18"/>

              <TextBlock Style="{StaticResource Label}" Text="Name"/>
              <TextBox x:Name="EditName" MaxLength="40"/>

              <TextBlock Style="{StaticResource Label}" Text="Destination folder" Margin="0,16,0,6"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="EditFolder"/>
                <Button x:Name="BtnBrowseFolder" Grid.Column="1" Style="{StaticResource Btn}" Margin="8,0,0,0">
                  <StackPanel Orientation="Horizontal"><Path Data="{StaticResource FolderGeo}" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.4" StrokeLineJoin="Round" Width="16" Height="13" Stretch="Uniform" VerticalAlignment="Center" Margin="0,0,9,0"/><TextBlock Text="Browse"/></StackPanel>
                </Button>
              </Grid>
              <TextBlock x:Name="EditFolderHint" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0"/>

              <TextBlock Style="{StaticResource Label}" Text="File types" Margin="0,16,0,6"/>
              <TextBox x:Name="EditExtensions" Height="62" TextWrapping="Wrap" AcceptsReturn="False" VerticalContentAlignment="Top" Padding="10,8"/>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" Text="Extensions separated by spaces or commas, for example:  pdf docx txt"/>

              <TextBlock Style="{StaticResource Label}" Text="Name keywords (optional)" Margin="0,16,0,6"/>
              <TextBox x:Name="EditKeywords"/>
              <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" Text="Files whose name contains one of these words go here first, for example:  invoice, receipt. If file types are also set, both must match."/>

              <TextBlock Style="{StaticResource Label}" Text="Color" Margin="0,16,0,4"/>
              <StackPanel x:Name="SwatchPanel" Orientation="Horizontal"/>

              <CheckBox x:Name="EditEnabled" Content="Sort files into this category" Margin="0,18,0,0"/>

              <StackPanel Orientation="Horizontal" Margin="0,24,0,0">
                <Button x:Name="BtnSaveCategory" Style="{StaticResource BtnPrimary}" Content="Save category" MinWidth="130"/>
                <Button x:Name="BtnDeleteCategory" Style="{StaticResource BtnDanger}" Content="Delete" Margin="8,0,0,0"/>
                <TextBlock x:Name="EditorSaved" Foreground="{DynamicResource AccentText}" VerticalAlignment="Center" Margin="16,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </Grid>
    </Grid>

    <!-- ============================== History ============================== -->
    <Grid x:Name="PageHistory" Grid.Column="1" Margin="14,22,28,20" Visibility="Collapsed">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel>
        <TextBlock Style="{StaticResource H1}" Text="History"/>
        <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,0" Text="Every run is remembered. Undo puts the files back exactly where they were."/>
      </StackPanel>
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0">
        <Grid>
          <ListBox x:Name="HistoryList" Margin="6" ItemContainerStyle="{StaticResource Row}">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid Margin="14,11,12,11">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Border Width="38" Height="38" CornerRadius="19" Background="{DynamicResource AccentSoft}" HorizontalAlignment="Left">
                    <Path Data="{StaticResource FolderGeo}" Fill="{DynamicResource AccentText}" Width="18" Height="14" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Title}" FontFamily="Segoe UI Semibold"/>
                    <TextBlock Text="{Binding Sub}" Foreground="{DynamicResource Muted}" FontSize="12" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <Button Grid.Column="2" Style="{StaticResource Btn}" Height="32" Content="Undo" Tag="{Binding Id}" Visibility="{Binding UndoVisibility}"/>
                  <TextBlock Grid.Column="2" Text="Undone" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="{Binding UndoneVisibility}"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <StackPanel x:Name="HistoryEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
            <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="{DynamicResource Muted}" HorizontalAlignment="Center"/>
            <TextBlock Text="No runs yet" FontFamily="Segoe UI Semibold" FontSize="17" HorizontalAlignment="Center" Margin="0,14,0,0"/>
            <TextBlock Style="{StaticResource Sub}" Text="When you organize your files, the run appears here." Margin="0,6,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ============================== Safety ============================== -->
    <ScrollViewer x:Name="PageSafety" Grid.Column="1" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="14,22,28,20">
        <TextBlock Style="{StaticResource H1}" Text="Safety"/>
        <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,20" Text="Organizer only moves loose personal files. Windows, installed programs and anything that could break by being moved stay exactly where they are."/>

        <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,0,12">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Border Width="34" Height="34" CornerRadius="17" Background="{DynamicResource AccentSoft}" Margin="0,0,14,0">
                <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentText}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="SafetyNowTitle" FontFamily="Segoe UI Semibold" FontSize="14"/>
                <TextBlock x:Name="SafetyNowText" Style="{StaticResource Sub}" Margin="0,2,0,0"/>
              </StackPanel>
            </StackPanel>
            <ItemsControl x:Name="SafetyNowList" Margin="0,14,0,0">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="2,9">
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="3*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
                      <TextBlock Grid.Column="1" Text="{Binding Reason}" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Reason}"/>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </StackPanel>
        </Border>

        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,6,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Places Organizer never touches"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,6" Text="They cannot be organized and no category can send files into them."/>
              <ItemsControl x:Name="SafetyZones">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Margin="0,10,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{DynamicResource AccentText}" Margin="0,3,0,0"/>
                      <StackPanel Grid.Column="1">
                        <TextBlock Text="{Binding Name}" FontFamily="Segoe UI Semibold"/>
                        <TextBlock Text="{Binding Path}" Foreground="{DynamicResource Muted}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                        <TextBlock Text="{Binding Note}" Foreground="{DynamicResource Muted}" FontSize="12" TextWrapping="Wrap"/>
                      </StackPanel>
                    </Grid>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Padding="22,18" Margin="6,0,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Checks every file must pass"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,6" Text="A file that fails any check is left alone and listed above with the reason."/>
              <ItemsControl x:Name="SafetyChecks">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Grid Margin="0,10,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{DynamicResource AccentText}" Margin="0,3,0,0"/>
                      <StackPanel Grid.Column="1">
                        <TextBlock Text="{Binding Name}" FontFamily="Segoe UI Semibold" TextWrapping="Wrap"/>
                        <TextBlock Text="{Binding Note}" Foreground="{DynamicResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
                      </StackPanel>
                    </Grid>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
        </Grid>
      </StackPanel>
    </ScrollViewer>

    <!-- ============================== Settings ============================== -->
    <ScrollViewer x:Name="PageSettings" Grid.Column="1" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="14,22,28,20" MaxWidth="820" HorizontalAlignment="Left">
        <TextBlock Style="{StaticResource H1}" Text="Settings"/>
        <TextBlock Style="{StaticResource Sub}" Margin="0,5,0,20" Text="Changes are saved automatically."/>

        <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Folder to organize"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,12" Text="Organizer sorts the files directly inside this folder. Folders inside it stay where they are."/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="SetSource" IsReadOnly="True"/>
              <Button x:Name="BtnSetSource" Grid.Column="1" Style="{StaticResource Btn}" Margin="8,0,0,0" Content="Change"/>
              <Button x:Name="BtnResetSource" Grid.Column="2" Style="{StaticResource Btn}" Margin="8,0,0,0" Content="Use Downloads"/>
            </Grid>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Date folders"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,12" Text="Add a folder for the date each file was last changed, for example  Images\2026\2026-11."/>
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="DateNone" Style="{StaticResource Seg}" GroupName="Date" Content="Off"/>
              <RadioButton x:Name="DateYear" Style="{StaticResource Seg}" GroupName="Date" Content="By year"/>
              <RadioButton x:Name="DateMonth" Style="{StaticResource Seg}" GroupName="Date" Content="By year and month"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Smart detection"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,12" Text="When a file has no extension or an unknown one, Organizer reads its first bytes to find out what it really is (PDF, image, video, archive and more)."/>
            <CheckBox x:Name="SetDetect" Content="Detect the file type from its content"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Padding="22,18" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" FontSize="14" Text="Theme" Margin="0,0,0,12"/>
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="ThemeSystem" Style="{StaticResource Seg}" GroupName="Theme" Content="Match Windows"/>
              <RadioButton x:Name="ThemeDark" Style="{StaticResource Seg}" GroupName="Theme" Content="Dark"/>
              <RadioButton x:Name="ThemeLight" Style="{StaticResource Seg}" GroupName="Theme" Content="Light"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}" Padding="22,18">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="AboutText" Style="{StaticResource Label}" FontSize="14" Text="Organizer"/>
              <TextBlock Style="{StaticResource Sub}" Text="Your settings and run history are stored on this PC only."/>
            </StackPanel>
            <Button x:Name="BtnOpenData" Grid.Column="1" Style="{StaticResource Btn}" Content="Open settings folder" VerticalAlignment="Center"/>
          </Grid>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($match in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
    $name = $match.Groups[1].Value
    $control = $window.FindName($name)
    if ($control) { $ui[$name] = $control }
}

# ------------------------------------------------------------------------------------------------
#  State
# ------------------------------------------------------------------------------------------------
$script:Settings  = Read-OrganizerSettings
$script:Plan      = $null
$script:Filter    = $null
$script:Busy      = $false
$script:Loading   = $true
$script:PlanDirty = $false
$script:LastRunId = $null
$script:EditId    = $null
$script:Palette   = $script:Palettes.Dark
$script:Arrow     = [string][char]0x2192
$script:Dot       = ' ' + [char]0x00B7 + ' '

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch {
        [void][System.Windows.MessageBox]::Show($window, ("Something went wrong:`r`n`r`n{0}" -f $_.Exception.Message), 'Organizer', 'OK', 'Warning')
    }
}

function Get-Plural([int]$Count, [string]$Word) { if ($Count -eq 1) { "1 $Word" } else { '{0:N0} {1}s' -f $Count, $Word } }

function Invoke-UiPump {
    # Lets the window repaint while a long loop is running.
    $window.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# ------------------------------------------------------------------------------------------------
#  Theme
# ------------------------------------------------------------------------------------------------
function Test-SystemDark {
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) }
    catch { return $true }
}

function Update-Theme {
    $name = $script:Settings.Theme
    if ($PreviewTheme) { $name = $PreviewTheme }
    if ($name -ne 'Dark' -and $name -ne 'Light') { $name = if (Test-SystemDark) { 'Dark' } else { 'Light' } }
    $script:Palette = $script:Palettes[$name]
    $converter = New-Object System.Windows.Media.BrushConverter
    foreach ($key in $script:Palette.Keys) {
        $brush = $converter.ConvertFromString($script:Palette[$key])
        $brush.Freeze()
        $window.Resources[$key] = $brush
    }
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($handle -ne [IntPtr]::Zero) {
            [OrganizerNative.Dwm]::Set($handle, 20, [int]($name -eq 'Dark'))
            $c = [System.Windows.Media.ColorConverter]::ConvertFromString($script:Palette.Bg)
            [OrganizerNative.Dwm]::Set($handle, 35, ([int]$c.R + 256 * [int]$c.G + 65536 * [int]$c.B))
        }
    }
    catch { }
    if ($script:Plan) { Update-PlanView }
}

function New-AppIcon {
    try {
        $visual = New-Object System.Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        $brush = New-Object System.Windows.Media.LinearGradientBrush(
            [System.Windows.Media.Color]::FromRgb(43, 199, 169), [System.Windows.Media.Color]::FromRgb(59, 111, 224), 45)
        $dc.DrawRoundedRectangle($brush, $null, (New-Object System.Windows.Rect(2, 2, 60, 60)), 15, 15)
        $folder = [System.Windows.Media.Geometry]::Parse('M2,6 A2,2 0 0 1 4,4 H9 L11.5,6.5 H20 A2,2 0 0 1 22,8.5 V18 A2,2 0 0 1 20,20 H4 A2,2 0 0 1 2,18 Z').Clone()
        $group = New-Object System.Windows.Media.TransformGroup
        $group.Children.Add((New-Object System.Windows.Media.ScaleTransform(1.7, 1.7)))
        $group.Children.Add((New-Object System.Windows.Media.TranslateTransform(11.6, 11.6)))
        $folder.Transform = $group
        $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $folder)
        $dc.Close()
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $bitmap.Freeze()
        $window.Icon = $bitmap
    }
    catch { }
}

# ------------------------------------------------------------------------------------------------
#  Organize page
# ------------------------------------------------------------------------------------------------
function Get-VisibleItems {
    if (-not $script:Plan) { return @() }
    $search = $ui.SearchBox.Text.Trim()
    @($script:Plan.Items | Where-Object {
            (-not $script:Filter -or $_.CategoryId -eq $script:Filter) -and
            (-not $search -or $_.Name.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
}

function Update-PlanCounts {
    $all = @($script:Plan.Items)
    $chosen = @($all | Where-Object { $_.Include })
    $bytes = 0; foreach ($item in $chosen) { $bytes += $item.Size }
    $folders = @($chosen | ForEach-Object { $_.DestinationFolder } | Sort-Object -Unique).Count
    $ui.StatFiles.Text = '{0:N0}' -f $chosen.Count
    $ui.StatSize.Text = Format-OrganizerSize $bytes
    $ui.StatFolders.Text = '{0:N0}' -f $folders
    $ui.BtnOrganize.Content = if ($chosen.Count -gt 0) { 'Organize ' + (Get-Plural $chosen.Count 'file') } else { 'Organize' }
    $ui.BtnOrganize.IsEnabled = ($chosen.Count -gt 0 -and -not $script:Busy)
    $visible = @(Get-VisibleItems)
    $visibleOn = @($visible | Where-Object { $_.Include }).Count
    $ui.ChkAll.IsChecked = ($visible.Count -gt 0 -and $visibleOn -eq $visible.Count)
    $ui.ChkAll.IsEnabled = ($visible.Count -gt 0)
    $ui.ShownText.Text = if ($visible.Count -ne $all.Count) { 'Showing {0:N0} of {1:N0}' -f $visible.Count, $all.Count } else { '' }
}

function Update-PlanView {
    $plan = $script:Plan
    $all = @($plan.Items)
    $visible = @(Get-VisibleItems)
    $ui.PlanList.ItemsSource = $visible

    # One chip per category that has files; clicking a chip filters the list.
    $chips = New-Object System.Collections.ArrayList
    if ($all.Count -gt 0) {
        $selected = (-not $script:Filter)
        [void]$chips.Add([pscustomobject]@{ Id = ''; Name = 'All files'; Count = $all.Count; Color = $script:Palette.AccentText
                Fill = $(if ($selected) { $script:Palette.NavSel } else { $script:Palette.Card })
                Stroke = $(if ($selected) { $script:Palette.Accent } else { $script:Palette.Border }) })
        foreach ($group in ($all | Group-Object CategoryId | Sort-Object Count -Descending)) {
            $selected = ($script:Filter -eq $group.Name)
            [void]$chips.Add([pscustomobject]@{ Id = $group.Name; Name = $group.Group[0].Category; Count = $group.Count; Color = $group.Group[0].Color
                    Fill = $(if ($selected) { $script:Palette.NavSel } else { $script:Palette.Card })
                    Stroke = $(if ($selected) { $script:Palette.Accent } else { $script:Palette.Border }) })
        }
    }
    $ui.ChipList.ItemsSource = @($chips)

    $guarded = @($plan.Protected).Count
    $untouched = $plan.Folders + $guarded + $plan.Unknown
    $ui.StatSkipped.Text = '{0:N0}' -f $untouched
    $details = @()
    if ($plan.Folders) { $details += Get-Plural $plan.Folders 'folder' }
    if ($guarded) { $details += (Get-Plural $guarded 'protected file') + ' (program files, files in use, unfinished downloads...)' }
    if ($plan.Unknown) { $details += (Get-Plural $plan.Unknown 'file') + ' with no matching category' }
    $ui.StatSkippedCard.ToolTip = $(if ($details.Count) { $details -join "`r`n" } else { 'Nothing was skipped.' }) + "`r`n`r`nClick to see the Safety page."

    if ($visible.Count -eq 0) {
        $ui.EmptyState.Visibility = 'Visible'
        if ($plan.Error) {
            $ui.EmptyIcon.Text = [string][char]0xE7BA
            $ui.EmptyTitle.Text = 'This folder cannot be organized'
            $ui.EmptyText.Text = $plan.Error + ' You can choose another folder in Settings.'
        }
        elseif ($all.Count -gt 0) {
            $ui.EmptyIcon.Text = [string][char]0xE721
            $ui.EmptyTitle.Text = 'No matching files'
            $ui.EmptyText.Text = 'Try another search or choose "All files".'
        }
        else {
            $ui.EmptyIcon.Text = [string][char]0xE73E
            $ui.EmptyTitle.Text = 'Everything is tidy'
            $ui.EmptyText.Text = 'There are no loose files to sort in this folder. New downloads will show up here after "Scan again".'
        }
    }
    else { $ui.EmptyState.Visibility = 'Collapsed' }
    Update-PlanCounts
}

function Start-Scan {
    if ($script:Busy) { return }
    $source = Get-OrganizerSource $script:Settings
    $leaf = [IO.Path]::GetFileName($source)
    $ui.OrganizeTitle.Text = if ($leaf -ieq 'Downloads') { 'Organize your Downloads' } else { "Organize $leaf" }
    $ui.SourceText.Text = $source
    $script:Plan = Get-OrganizerPlan $script:Settings
    if ($script:Filter -and -not ($script:Plan.Items | Where-Object { $_.CategoryId -eq $script:Filter })) { $script:Filter = $null }
    $script:PlanDirty = $false
    Update-PlanView
}

function Set-Busy([bool]$Busy) {
    $script:Busy = $Busy
    foreach ($name in 'BtnScan', 'NavCategories', 'NavHistory', 'NavSafety', 'NavSettings', 'PlanList', 'ChkAll', 'SearchBox', 'ChipList', 'BtnBannerUndo') {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.BtnOrganize.IsEnabled = -not $Busy
    $ui.ProgressPanel.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $ui.FooterText.Visibility = if ($Busy) { 'Collapsed' } else { 'Visible' }
}

function Show-Banner([string]$Text, [string]$RunId) {
    $ui.BannerText.Text = $Text
    $script:LastRunId = $RunId
    $ui.BtnBannerUndo.Visibility = if ($RunId) { 'Visible' } else { 'Collapsed' }
    $ui.Banner.Visibility = 'Visible'
}

function Start-Organize {
    if ($script:Busy -or -not $script:Plan) { return }
    $items = @($script:Plan.Items | Where-Object { $_.Include })
    if ($items.Count -eq 0) { return }
    $space = Get-OrganizerSpaceProblem -Items $items
    if ($space) { throw $space }
    Set-Busy $true
    $ui.Banner.Visibility = 'Collapsed'
    $ui.Progress.Maximum = $items.Count
    $ui.Progress.Value = 0
    $script:LastPump = [Environment]::TickCount
    try {
        $result = Invoke-OrganizerPlan -Items $items -Source $script:Plan.Source -OnProgress {
            param($Index, $Total, $Name)
            if ($Index -eq 1 -or $Index -eq $Total -or ([Environment]::TickCount - $script:LastPump) -gt 40) {
                $ui.Progress.Value = $Index
                $ui.ProgressText.Text = 'Moving {0:N0} of {1:N0}{2}{3}' -f $Index, $Total, $script:Dot, $Name
                Invoke-UiPump
                $script:LastPump = [Environment]::TickCount
            }
        }
    }
    finally { Set-Busy $false }

    $text = 'Moved {0} ({1}) into {2}.' -f (Get-Plural $result.Moved 'file'), (Format-OrganizerSize $result.Bytes), (Get-Plural $result.Folders 'folder')
    if ($result.Failed.Count -gt 0) {
        $first = $result.Failed[0]
        $text += ' {0} could not be moved and stayed where they were (for example "{1}": {2})' -f (Get-Plural $result.Failed.Count 'file'), $first.Name, $first.Error
    }
    Show-Banner $text $result.Id
    Start-Scan
}

function Start-Undo([string]$RunId) {
    if ($script:Busy -or -not $RunId) { return }
    $result = Undo-OrganizerRun -Id $RunId
    $text = 'Put {0} back where {1}.' -f (Get-Plural $result.Restored 'file'), $(if ($result.Restored -eq 1) { 'it was' } else { 'they were' })
    if ($result.Missing -gt 0) { $text += ' {0} could not be found any more.' -f (Get-Plural $result.Missing 'file') }
    Show-Banner $text $null
    Start-Scan
    Update-HistoryPage
}

# ------------------------------------------------------------------------------------------------
#  Categories page
# ------------------------------------------------------------------------------------------------
function Update-CategoryList([string]$SelectId) {
    $rows = @(foreach ($category in $script:Settings.Categories) {
            $sub = if ($category.Id -eq 'other') { 'Everything that fits nowhere else' }
            else {
                $parts = @()
                if (@($category.Keywords).Count) { $parts += '"' + (@($category.Keywords)[0..([Math]::Min(1, @($category.Keywords).Count - 1))] -join '", "') + '"' }
                if (@($category.Extensions).Count) { $parts += (@($category.Extensions)[0..([Math]::Min(4, @($category.Extensions).Count - 1))] -join ' ') }
                if ($parts.Count) { $parts -join $script:Dot } else { 'No file types yet' }
            }
            $badge = if (-not $category.Enabled) { 'OFF' } elseif (-not $category.BuiltIn) { 'CUSTOM' } else { '' }
            [pscustomobject]@{ Id = $category.Id; Name = $category.Name; Sub = $sub; Color = $category.Color; Badge = $badge }
        })
    $script:Loading = $true
    $ui.CategoryList.ItemsSource = $rows
    $pick = $rows | Where-Object { $_.Id -eq $SelectId } | Select-Object -First 1
    if ($pick) { $ui.CategoryList.SelectedItem = $pick; $ui.CategoryList.ScrollIntoView($pick) } else { $ui.CategoryList.SelectedItem = $null }
    $script:Loading = $false
}

function Update-FolderHint {
    $text = $ui.EditFolder.Text.Trim()
    $source = Get-OrganizerSource $script:Settings
    $resolved = if ($text) { Resolve-OrganizerFolder $text $source } elseif ($ui.EditName.Text.Trim()) { Resolve-OrganizerFolder $ui.EditName.Text $source } else { $null }
    $problem = if ($resolved) { Test-OrganizerPathProtected $resolved -AsDestination } else { $null }
    $ui.EditFolderHint.Foreground = $window.Resources[$(if ($problem) { 'Danger' } else { 'Muted' })]
    $ui.EditFolderHint.Text = if ($problem) { "Not allowed:  $problem" } elseif ($resolved) { "Files go to:  $resolved" }
    else { 'Type a folder name to create it inside the organized folder, or use Browse to pick any folder on your PC.' }
}

function Set-Swatch([string]$Color) {
    $found = $false
    foreach ($swatch in $ui.SwatchPanel.Children) {
        $swatch.IsChecked = ($swatch.Tag -ieq $Color)
        if ($swatch.IsChecked) { $found = $true }
    }
    if (-not $found) { $ui.SwatchPanel.Children[0].IsChecked = $true }
}

function Show-CategoryEditor($Category) {
    $script:Loading = $true
    $ui.EditorSaved.Text = ''
    if ($Category) {
        $script:EditId = $Category.Id
        $isOther = ($Category.Id -eq 'other')
        $ui.EditorTitle.Text = $Category.Name
        $ui.EditorNote.Text = if ($isOther) { 'Catches every file that no other category wants. Turn it off to leave those files where they are.' }
        elseif ($Category.BuiltIn) { 'Built-in category. You can change everything about it.' } else { 'Your own category.' }
        $ui.EditName.Text = $Category.Name
        $ui.EditFolder.Text = $Category.Folder
        $ui.EditExtensions.Text = @($Category.Extensions) -join ' '
        $ui.EditKeywords.Text = @($Category.Keywords) -join ', '
        $ui.EditEnabled.IsChecked = [bool]$Category.Enabled
        $ui.EditExtensions.IsEnabled = -not $isOther
        $ui.EditKeywords.IsEnabled = -not $isOther
        $ui.BtnDeleteCategory.Visibility = if ($isOther) { 'Collapsed' } else { 'Visible' }
        $ui.BtnSaveCategory.Content = 'Save category'
        Set-Swatch $Category.Color
    }
    else {
        $script:EditId = $null
        $ui.EditorTitle.Text = 'New category'
        $ui.EditorNote.Text = 'Give it a name, choose where the files should go and which files belong to it.'
        $ui.EditName.Text = ''; $ui.EditFolder.Text = ''; $ui.EditExtensions.Text = ''; $ui.EditKeywords.Text = ''
        $ui.EditEnabled.IsChecked = $true
        $ui.EditExtensions.IsEnabled = $true; $ui.EditKeywords.IsEnabled = $true
        $ui.BtnDeleteCategory.Visibility = 'Collapsed'
        $ui.BtnSaveCategory.Content = 'Add category'
        Set-Swatch $script:Swatches[(@($script:Settings.Categories).Count % $script:Swatches.Count)]
    }
    $script:Loading = $false
    Update-FolderHint
}

function Save-Category {
    $name = $ui.EditName.Text.Trim()
    if (-not $name) { throw 'Please give the category a name.' }
    $clash = $script:Settings.Categories | Where-Object { $_.Name -ieq $name -and $_.Id -ne $script:EditId }
    if ($clash) { throw "There is already a category named `"$name`"." }
    $folder = $ui.EditFolder.Text.Trim()
    if (-not $folder) { $folder = $name }
    $resolved = Resolve-OrganizerFolder $folder (Get-OrganizerSource $script:Settings)
    if (-not $resolved) { throw 'The destination folder is not a valid folder name or path.' }
    $problem = Test-OrganizerPathProtected $resolved -AsDestination
    if ($problem) { throw "This destination folder cannot be used.`r`n`r`n$problem" }
    $extensions = ConvertTo-OrganizerList $ui.EditExtensions.Text -Extension
    $keywords = ConvertTo-OrganizerList $ui.EditKeywords.Text
    if ($script:EditId -ne 'other' -and $extensions.Count -eq 0 -and $keywords.Count -eq 0) {
        throw 'Add at least one file type or one name keyword, so Organizer knows which files belong here.'
    }
    $color = ($ui.SwatchPanel.Children | Where-Object { $_.IsChecked } | Select-Object -First 1).Tag
    $existing = $script:Settings.Categories | Where-Object { $_.Id -eq $script:EditId } | Select-Object -First 1
    $category = New-OrganizerCategory -Id $script:EditId -Name $name -Folder $folder -Extensions $extensions -Keywords $keywords -Color $color `
        -Enabled ([bool]$ui.EditEnabled.IsChecked) -BuiltIn ([bool]($existing -and $existing.BuiltIn))
    if ($existing) {
        $script:Settings.Categories = @($script:Settings.Categories | ForEach-Object { if ($_.Id -eq $category.Id) { $category } else { $_ } })
    }
    else {
        # New categories go first so their rules win over the built-in ones; "Other" always stays last.
        $script:Settings.Categories = @($category) + @($script:Settings.Categories)
    }
    Save-OrganizerSettings $script:Settings
    $script:PlanDirty = $true
    Update-CategoryList $category.Id
    Show-CategoryEditor $category
    $ui.EditorSaved.Text = 'Saved'
}

function Remove-Category {
    $category = $script:Settings.Categories | Where-Object { $_.Id -eq $script:EditId } | Select-Object -First 1
    if (-not $category -or $category.Id -eq 'other') { return }
    $answer = [System.Windows.MessageBox]::Show($window,
        ("Delete the category `"{0}`"?`r`n`r`nOnly the sorting rule is removed. The folder and the files in it stay." -f $category.Name),
        'Organizer', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $script:Settings.Categories = @($script:Settings.Categories | Where-Object { $_.Id -ne $category.Id })
    Save-OrganizerSettings $script:Settings
    $script:PlanDirty = $true
    $first = $script:Settings.Categories[0]
    Update-CategoryList $first.Id
    Show-CategoryEditor $first
}

# ------------------------------------------------------------------------------------------------
#  History and settings pages
# ------------------------------------------------------------------------------------------------
function Update-HistoryPage {
    $rows = @(foreach ($run in (Get-OrganizerHistory)) {
            [pscustomobject]@{
                Id = $run.Id
                Title = 'Moved {0}{1}{2}' -f (Get-Plural $run.Count 'file'), $script:Dot, (Format-OrganizerSize $run.Bytes)
                Sub = '{0}{1}{2}' -f $run.Time.ToString('dddd, d MMMM yyyy, HH:mm'), $script:Dot, $run.Source
                UndoVisibility = $(if ($run.Undone) { 'Collapsed' } else { 'Visible' })
                UndoneVisibility = $(if ($run.Undone) { 'Visible' } else { 'Collapsed' })
            }
        })
    $ui.HistoryList.ItemsSource = $rows
    $ui.HistoryEmpty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
}

function Update-SafetyPage {
    $plan = $script:Plan
    $protected = @(if ($plan) { $plan.Protected })
    $leaf = if ($plan) { [IO.Path]::GetFileName($plan.Source) } else { 'the folder' }
    if ($plan -and $plan.Error) {
        $ui.SafetyNowTitle.Text = 'This folder is refused'
        $ui.SafetyNowText.Text = $plan.Error
    }
    elseif ($protected.Count -gt 0) {
        $ui.SafetyNowTitle.Text = '{0} in {1} {2} protected right now' -f (Get-Plural $protected.Count 'file'), $leaf, $(if ($protected.Count -eq 1) { 'is' } else { 'are' })
        $ui.SafetyNowText.Text = 'They stay where they are. Everything else was checked and is safe to sort.'
    }
    else {
        $ui.SafetyNowTitle.Text = 'No file needed protection in the last scan'
        $ui.SafetyNowText.Text = "Every loose file in $leaf passed all safety checks."
    }
    $ui.SafetyNowList.ItemsSource = @($protected | Select-Object -First 200)
    $ui.SafetyZones.ItemsSource = @(Get-OrganizerProtectedZone)
    $ui.SafetyChecks.ItemsSource = @(
        [pscustomobject]@{ Name = 'Only loose files are sorted'; Note = 'Folders are never moved, opened or renamed. Only files lying directly in the organized folder are looked at.' }
        [pscustomobject]@{ Name = 'Programs stay together'; Note = 'An .exe with its .dll or settings files next to it is recognised as a program and left alone, together with all its parts.' }
        [pscustomobject]@{ Name = 'Program and project folders are refused'; Note = 'A folder with an uninstaller, many .dll files or a code repository inside cannot be chosen for organizing.' }
        [pscustomobject]@{ Name = 'Nothing in use is moved'; Note = 'Files open in another program, unfinished downloads, hidden and system files, links and online-only cloud files are skipped.' }
        [pscustomobject]@{ Name = 'Destinations are checked too'; Note = 'No category can send files into a protected place. This is checked when you save it and again at the moment of moving.' }
        [pscustomobject]@{ Name = 'Nothing is deleted or overwritten'; Note = 'Name clashes get a number, free space is checked before moving to another drive, and every run can be undone.' }
    )
}

function Update-SettingsPage {
    $script:Loading = $true
    $ui.SetSource.Text = Get-OrganizerSource $script:Settings
    $ui.BtnResetSource.IsEnabled = -not [string]::IsNullOrWhiteSpace($script:Settings.SourceFolder)
    $ui.DateNone.IsChecked = ($script:Settings.DateFolders -eq 'None')
    $ui.DateYear.IsChecked = ($script:Settings.DateFolders -eq 'Year')
    $ui.DateMonth.IsChecked = ($script:Settings.DateFolders -eq 'Month')
    $ui.SetDetect.IsChecked = [bool]$script:Settings.DetectContent
    $ui.ThemeSystem.IsChecked = ($script:Settings.Theme -eq 'System')
    $ui.ThemeDark.IsChecked = ($script:Settings.Theme -eq 'Dark')
    $ui.ThemeLight.IsChecked = ($script:Settings.Theme -eq 'Light')
    $ui.AboutText.Text = "Organizer $($script:AppVersion)"
    $script:Loading = $false
}

function Save-Setting([string]$Name, $Value) {
    if ($script:Loading) { return }
    $script:Settings.$Name = $Value
    Save-OrganizerSettings $script:Settings
    $script:PlanDirty = $true
}

function Select-Folder([string]$Description, [string]$Start) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($Start -and [IO.Directory]::Exists($Start)) { $dialog.SelectedPath = $Start }
    try { if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath } }
    finally { $dialog.Dispose() }
    return $null
}

function Show-Page([string]$Id) {
    foreach ($page in 'Organize', 'Categories', 'History', 'Safety', 'Settings') {
        $ui["Page$page"].Visibility = if ($page -eq $Id) { 'Visible' } else { 'Collapsed' }
    }
    switch ($Id) {
        'Organize' { if ($script:PlanDirty -or -not $script:Plan) { Start-Scan } }
        'Categories' {
            $keep = if ($script:EditId) { $script:EditId } else { $script:Settings.Categories[0].Id }
            Update-CategoryList $keep
            Show-CategoryEditor ($script:Settings.Categories | Where-Object { $_.Id -eq $keep } | Select-Object -First 1)
        }
        'History' { Update-HistoryPage }
        'Safety' { if ($script:PlanDirty -or -not $script:Plan) { Start-Scan }; Update-SafetyPage }
        'Settings' { Update-SettingsPage }
    }
}

# ------------------------------------------------------------------------------------------------
#  Events
# ------------------------------------------------------------------------------------------------
foreach ($page in 'Organize', 'Categories', 'History', 'Safety', 'Settings') {
    $ui["Nav$page"].Tag = $ui["Nav$page"].Tag   # keep the icon glyph
    $ui["Nav$page"].Add_Checked([System.Windows.RoutedEventHandler] {
            param($sender, $e)
            if (-not $script:Loading) { Invoke-Safely { Show-Page ($sender.Name.Substring(3)) } }
        })
}

$ui.BtnScan.Add_Click({ Invoke-Safely { $ui.Banner.Visibility = 'Collapsed'; Start-Scan } })
$ui.BtnOrganize.Add_Click({ Invoke-Safely { Start-Organize } })
$ui.BtnOpenSource.Add_Click({ Invoke-Safely {
            $source = Get-OrganizerSource $script:Settings
            if ([IO.Directory]::Exists($source)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $source) }
        } })
$ui.BtnBannerUndo.Add_Click({ Invoke-Safely { Start-Undo $script:LastRunId } })
$ui.BtnBannerClose.Add_Click({ $ui.Banner.Visibility = 'Collapsed' })
$ui.StatSkippedCard.Add_MouseLeftButtonUp({ if (-not $script:Busy) { $ui.NavSafety.IsChecked = $true } })
$ui.SearchBox.Add_TextChanged({ Invoke-Safely {
            $ui.SearchHint.Visibility = if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
            if ($script:Plan) { Update-PlanView }
        } })
$ui.ChkAll.Add_Click({ Invoke-Safely {
            $on = [bool]$ui.ChkAll.IsChecked
            foreach ($item in (Get-VisibleItems)) { $item.Include = $on }
            Update-PlanView
        } })

$clickEvent = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
$ui.PlanList.AddHandler($clickEvent, [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        $box = $e.OriginalSource
        if ($box -is [System.Windows.Controls.CheckBox] -and $box.DataContext) {
            Invoke-Safely { $box.DataContext.Include = [bool]$box.IsChecked; Update-PlanCounts }
        }
    })
$ui.ChipList.AddHandler($clickEvent, [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
            Invoke-Safely { $id = [string]$e.OriginalSource.Tag; $script:Filter = $(if ($id) { $id } else { $null }); Update-PlanView }
        }
    })
$ui.HistoryList.AddHandler($clickEvent, [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button] -and $e.OriginalSource.Tag) {
            Invoke-Safely { Start-Undo ([string]$e.OriginalSource.Tag); $script:PlanDirty = $true }
        }
    })

foreach ($color in $script:Swatches) {
    $swatch = New-Object System.Windows.Controls.RadioButton
    $swatch.Style = $window.FindResource('Swatch')
    $swatch.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
    $swatch.Tag = $color
    [void]$ui.SwatchPanel.Children.Add($swatch)
}
$ui.CategoryList.Add_SelectionChanged({ Invoke-Safely {
            if ($script:Loading -or -not $ui.CategoryList.SelectedItem) { return }
            $id = $ui.CategoryList.SelectedItem.Id
            Show-CategoryEditor ($script:Settings.Categories | Where-Object { $_.Id -eq $id } | Select-Object -First 1)
        } })
$ui.BtnNewCategory.Add_Click({ Invoke-Safely { Update-CategoryList $null; Show-CategoryEditor $null; [void]$ui.EditName.Focus() } })
$ui.BtnSaveCategory.Add_Click({ Invoke-Safely { Save-Category } })
$ui.BtnDeleteCategory.Add_Click({ Invoke-Safely { Remove-Category } })
$ui.BtnBrowseFolder.Add_Click({ Invoke-Safely {
            $picked = Select-Folder 'Choose the folder for this category' (Resolve-OrganizerFolder $ui.EditFolder.Text (Get-OrganizerSource $script:Settings))
            if ($picked) { $ui.EditFolder.Text = $picked }
        } })
$ui.EditFolder.Add_TextChanged({ if (-not $script:Loading) { Invoke-Safely { Update-FolderHint } } })
$ui.EditName.Add_TextChanged({ if (-not $script:Loading) { Invoke-Safely { Update-FolderHint } } })
$ui.BtnRestore.Add_Click({ Invoke-Safely {
            $answer = [System.Windows.MessageBox]::Show($window,
                "Restore the default categories?`r`n`r`nYour own categories and changes are removed. No files or folders are touched.",
                'Organizer', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { return }
            $script:Settings.Categories = @(Get-OrganizerDefaultCategory)
            Save-OrganizerSettings $script:Settings
            $script:PlanDirty = $true
            $script:EditId = $null
            Show-Page 'Categories'
        } })

$ui.BtnSetSource.Add_Click({ Invoke-Safely {
            $picked = Select-Folder 'Choose the folder Organizer should keep tidy' (Get-OrganizerSource $script:Settings)
            if (-not $picked) { return }
            $problem = Test-OrganizerSourceSafe $picked
            if ($problem) { throw $problem }
            Save-Setting 'SourceFolder' $picked
            Update-SettingsPage
        } })
$ui.BtnResetSource.Add_Click({ Invoke-Safely { Save-Setting 'SourceFolder' ''; Update-SettingsPage } })
$ui.DateNone.Add_Checked({ Invoke-Safely { Save-Setting 'DateFolders' 'None' } })
$ui.DateYear.Add_Checked({ Invoke-Safely { Save-Setting 'DateFolders' 'Year' } })
$ui.DateMonth.Add_Checked({ Invoke-Safely { Save-Setting 'DateFolders' 'Month' } })
$ui.SetDetect.Add_Click({ Invoke-Safely { Save-Setting 'DetectContent' ([bool]$ui.SetDetect.IsChecked) } })
$ui.ThemeSystem.Add_Checked({ Invoke-Safely { Save-Setting 'Theme' 'System'; if (-not $script:Loading) { Update-Theme } } })
$ui.ThemeDark.Add_Checked({ Invoke-Safely { Save-Setting 'Theme' 'Dark'; if (-not $script:Loading) { Update-Theme } } })
$ui.ThemeLight.Add_Checked({ Invoke-Safely { Save-Setting 'Theme' 'Light'; if (-not $script:Loading) { Update-Theme } } })
$ui.BtnOpenData.Add_Click({ Invoke-Safely { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Get-OrganizerDataDir)) } })

$window.Add_Closing({ param($sender, $e) if ($script:Busy) { $e.Cancel = $true } })
$window.Dispatcher.Add_UnhandledException({
        param($sender, $e)
        $e.Handled = $true
        [void][System.Windows.MessageBox]::Show(("Something went wrong:`r`n`r`n{0}" -f $e.Exception.Message), 'Organizer', 'OK', 'Warning')
    })

$window.Add_SourceInitialized({ Invoke-Safely { Update-Theme } })
$window.Add_ContentRendered({
        Invoke-Safely {
            if (-not $script:Plan) { Start-Scan }
            if ($PreviewTo) {
                $target = (Get-Culture).TextInfo.ToTitleCase($PreviewPage.ToLowerInvariant())
                if ($target -ne 'Organize') { $ui["Nav$target"].IsChecked = $true }
                Invoke-UiPump
                if ($PreviewAction -match 'toggle') {
                    $item = $ui.PlanList.ItemContainerGenerator.ContainerFromIndex(0)
                    $queue = New-Object System.Collections.Queue; $queue.Enqueue($item); $box = $null
                    while ($queue.Count -and -not $box) {
                        $node = $queue.Dequeue()
                        if ($node -is [System.Windows.Controls.CheckBox]) { $box = $node; break }
                        for ($k = 0; $k -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $k++) { $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $k)) }
                    }
                    $box.IsChecked = $false
                    $box.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
                }
                if ($PreviewAction -match 'organize') { Start-Organize }
                if ($PreviewAction -match 'undo') { Start-Undo $script:LastRunId }
                if ($env:ORGANIZER_PREVIEW_SOURCE) { $ui.SourceText.Text = $env:ORGANIZER_PREVIEW_SOURCE }
                Invoke-UiPump
                $root = $window.Content
                $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $visual = New-Object System.Windows.Media.DrawingVisual
                $dc = $visual.RenderOpen()
                $dc.DrawRectangle($window.Background, $null, (New-Object System.Windows.Rect(0, 0, $root.ActualWidth, $root.ActualHeight)))
                $dc.DrawRectangle((New-Object System.Windows.Media.VisualBrush($root)), $null, (New-Object System.Windows.Rect(0, 0, $root.ActualWidth, $root.ActualHeight)))
                $dc.Close()
                $bitmap.Render($visual)
                $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream = [IO.File]::Create($PreviewTo)
                try { $encoder.Save($stream) } finally { $stream.Dispose() }
                $window.Close()
            }
        }
    })

# ------------------------------------------------------------------------------------------------
#  Start
# ------------------------------------------------------------------------------------------------
New-AppIcon
Update-Theme
$script:Loading = $false
try { [void]$window.ShowDialog() }
finally {
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { }; $script:Mutex.Dispose() }
}
