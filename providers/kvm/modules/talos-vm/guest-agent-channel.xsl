<?xml version="1.0" encoding="UTF-8"?>
<!-- Domain XML tweaks the dmacvicar/libvirt provider cannot express:
     1. <readonly/> on the Talos ISO disk — without it qemu opens the ISO
        read-write and AppArmor denies the write mask.
     2. Per-device <boot order/>: the empty system disk is order 1, the ISO
        order 2 — SeaBIOS falls through to the isohybrid ISO until Talos is
        installed, then the disk boots directly and the ISO is inert.
     (The provider adds the qemu-guest-agent channel itself; do NOT inject
     a second one.) -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices/disk[contains(source/@file, '.iso') or contains(source/@volume, '.iso')]">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <xsl:if test="not(readonly)">
        <readonly/>
      </xsl:if>
      <xsl:if test="not(boot)">
        <boot order="2"/>
      </xsl:if>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices/disk[contains(source/@volume, '-system')]">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <xsl:if test="not(boot)">
        <boot order="1"/>
      </xsl:if>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
