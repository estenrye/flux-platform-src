<?xml version="1.0" encoding="UTF-8"?>
<!-- Domain XML tweaks the dmacvicar/libvirt provider cannot express:
     <readonly/> on the Talos ISO disk — without it qemu opens the ISO
     read-write and AppArmor denies the write mask. (The provider adds the
     qemu-guest-agent channel itself; do NOT inject a second one.) -->
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
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
